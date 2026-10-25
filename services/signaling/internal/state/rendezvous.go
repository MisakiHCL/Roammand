// SPDX-License-Identifier: AGPL-3.0-only

package state

import (
	"container/heap"
	"crypto/sha256"
	"errors"
	"strings"
	"sync"
	"time"
)

var (
	ErrRendezvousExists    = errors.New("rendezvous already exists")
	ErrPairingCodeExists   = errors.New("pairing code already exists")
	ErrRendezvousNotFound  = errors.New("rendezvous not found")
	ErrRendezvousFull      = errors.New("rendezvous already has a controller")
	ErrRendezvousSelfJoin  = errors.New("host cannot join its own rendezvous")
	ErrRendezvousNotMember = errors.New("device is not a rendezvous member")
	ErrRendezvousNotHost   = errors.New("device is not the rendezvous host")
	ErrRendezvousNotJoined = errors.New("rendezvous has no controller")
	ErrRendezvousInvalid   = errors.New("invalid rendezvous")
	ErrRendezvousLimit     = errors.New("device has too many active rendezvous")
	ErrRendezvousCapacity  = errors.New("rendezvous store is at capacity")
)

type PairingKind uint8

const (
	PairingKindQR PairingKind = iota + 1
	PairingKindDesktopCode
)

type Rendezvous struct {
	ID         RendezvousID
	Kind       PairingKind
	Host       DeviceID
	Controller *DeviceID
	CodeHash   [sha256.Size]byte
	ExpiresAt  time.Time
}

type RendezvousStore struct {
	mu          sync.RWMutex
	byID        map[RendezvousID]Rendezvous
	codeIndex   map[[sha256.Size]byte]RendezvousID
	memberIndex map[DeviceID]map[RendezvousID]struct{}
	hostCounts  map[DeviceID]int
	expirations rendezvousExpiryHeap
	expiryIndex map[RendezvousID]*rendezvousExpiry
	maxPerHost  int
	maxTotal    int
}

func NewRendezvousStore(maxPerHost int, maxTotal int) *RendezvousStore {
	if maxPerHost <= 0 {
		panic("maximum rendezvous per host must be positive")
	}
	if maxTotal <= 0 {
		panic("maximum rendezvous capacity must be positive")
	}
	return &RendezvousStore{
		byID:        make(map[RendezvousID]Rendezvous),
		codeIndex:   make(map[[sha256.Size]byte]RendezvousID),
		memberIndex: make(map[DeviceID]map[RendezvousID]struct{}),
		hostCounts:  make(map[DeviceID]int),
		expiryIndex: make(map[RendezvousID]*rendezvousExpiry),
		maxPerHost:  maxPerHost,
		maxTotal:    maxTotal,
	}
}

func (store *RendezvousStore) Create(
	rendezvous Rendezvous,
	pairingCode string,
	now time.Time,
) ([]Rendezvous, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	switch rendezvous.Kind {
	case PairingKindQR:
		if pairingCode != "" {
			return nil, ErrRendezvousInvalid
		}
	case PairingKindDesktopCode:
		if pairingCode == "" {
			return nil, ErrRendezvousInvalid
		}
		rendezvous.CodeHash = pairingCodeHash(pairingCode)
	default:
		return nil, ErrRendezvousInvalid
	}
	if !rendezvous.ExpiresAt.After(now) {
		return nil, ErrRendezvousInvalid
	}
	removed := store.sweepLocked(now)
	if _, exists := store.byID[rendezvous.ID]; exists {
		return removed, ErrRendezvousExists
	}
	if rendezvous.Kind == PairingKindDesktopCode {
		if _, exists := store.codeIndex[rendezvous.CodeHash]; exists {
			return removed, ErrPairingCodeExists
		}
	}
	if len(store.byID) >= store.maxTotal {
		return removed, ErrRendezvousCapacity
	}
	if store.hostCounts[rendezvous.Host] >= store.maxPerHost {
		return removed, ErrRendezvousLimit
	}

	stored := cloneRendezvous(rendezvous)
	store.byID[stored.ID] = stored
	expiry := &rendezvousExpiry{id: stored.ID, expiresAt: stored.ExpiresAt}
	heap.Push(&store.expirations, expiry)
	store.expiryIndex[stored.ID] = expiry
	store.indexMemberLocked(stored.Host, stored.ID)
	store.hostCounts[stored.Host]++
	if stored.Kind == PairingKindDesktopCode {
		store.codeIndex[stored.CodeHash] = stored.ID
	}
	return removed, nil
}

func (store *RendezvousStore) JoinByID(
	id RendezvousID,
	controller DeviceID,
	now time.Time,
) (Rendezvous, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	return store.joinLocked(id, controller, now)
}

func (store *RendezvousStore) JoinByCode(
	pairingCode string,
	controller DeviceID,
	now time.Time,
) (Rendezvous, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	id, exists := store.codeIndex[pairingCodeHash(pairingCode)]
	if !exists {
		return Rendezvous{}, ErrRendezvousNotFound
	}
	return store.joinLocked(id, controller, now)
}

func (store *RendezvousStore) Peer(
	id RendezvousID,
	sender DeviceID,
	now time.Time,
) (DeviceID, Rendezvous, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	rendezvous, err := store.activeLocked(id, now)
	if err != nil {
		return DeviceID{}, Rendezvous{}, err
	}
	if rendezvous.Controller == nil {
		return DeviceID{}, Rendezvous{}, ErrRendezvousNotJoined
	}
	if sender == rendezvous.Host {
		return *rendezvous.Controller, cloneRendezvous(rendezvous), nil
	}
	if sender == *rendezvous.Controller {
		return rendezvous.Host, cloneRendezvous(rendezvous), nil
	}
	return DeviceID{}, Rendezvous{}, ErrRendezvousNotMember
}

func (store *RendezvousStore) Complete(
	id RendezvousID,
	host DeviceID,
	now time.Time,
) (Rendezvous, error) {
	store.mu.Lock()
	defer store.mu.Unlock()

	rendezvous, err := store.activeLocked(id, now)
	if err != nil {
		return Rendezvous{}, err
	}
	if rendezvous.Host != host {
		return Rendezvous{}, ErrRendezvousNotHost
	}
	store.deleteLocked(rendezvous)
	return cloneRendezvous(rendezvous), nil
}

func (store *RendezvousStore) RemoveForDevice(deviceID DeviceID) []Rendezvous {
	store.mu.Lock()
	defer store.mu.Unlock()

	memberIDs := store.memberIndex[deviceID]
	removed := make([]Rendezvous, 0, len(memberIDs))
	for id := range memberIDs {
		rendezvous, exists := store.byID[id]
		if !exists {
			continue
		}
		removed = append(removed, cloneRendezvous(rendezvous))
		store.deleteLocked(rendezvous)
	}
	return removed
}

func (store *RendezvousStore) Sweep(now time.Time) []Rendezvous {
	store.mu.Lock()
	defer store.mu.Unlock()
	return store.sweepLocked(now)
}

func (store *RendezvousStore) sweepLocked(now time.Time) []Rendezvous {
	removed := make([]Rendezvous, 0)
	for len(store.expirations) > 0 {
		expiry := store.expirations[0]
		if expiry.expiresAt.After(now) {
			break
		}
		rendezvous := store.byID[expiry.id]
		removed = append(removed, cloneRendezvous(rendezvous))
		store.deleteLocked(rendezvous)
	}
	return removed
}

func (store *RendezvousStore) Len() int {
	store.mu.RLock()
	defer store.mu.RUnlock()
	return len(store.byID)
}

func (store *RendezvousStore) joinLocked(
	id RendezvousID,
	controller DeviceID,
	now time.Time,
) (Rendezvous, error) {
	rendezvous, err := store.activeLocked(id, now)
	if err != nil {
		return Rendezvous{}, err
	}
	if rendezvous.Host == controller {
		return Rendezvous{}, ErrRendezvousSelfJoin
	}
	if rendezvous.Controller != nil {
		if *rendezvous.Controller == controller {
			return cloneRendezvous(rendezvous), nil
		}
		return Rendezvous{}, ErrRendezvousFull
	}
	controllerCopy := controller
	rendezvous.Controller = &controllerCopy
	store.byID[id] = cloneRendezvous(rendezvous)
	store.indexMemberLocked(controller, id)
	return cloneRendezvous(rendezvous), nil
}

func (store *RendezvousStore) activeLocked(
	id RendezvousID,
	now time.Time,
) (Rendezvous, error) {
	rendezvous, exists := store.byID[id]
	if !exists {
		return Rendezvous{}, ErrRendezvousNotFound
	}
	if !rendezvous.ExpiresAt.After(now) {
		return Rendezvous{}, ErrRendezvousNotFound
	}
	return rendezvous, nil
}

func (store *RendezvousStore) deleteLocked(rendezvous Rendezvous) {
	stored, exists := store.byID[rendezvous.ID]
	if !exists {
		return
	}
	delete(store.byID, stored.ID)
	heap.Remove(&store.expirations, store.expiryIndex[stored.ID].index)
	delete(store.expiryIndex, stored.ID)
	store.removeMemberIndexLocked(stored.Host, stored.ID)
	if stored.Controller != nil {
		store.removeMemberIndexLocked(*stored.Controller, stored.ID)
	}
	if stored.Kind == PairingKindDesktopCode {
		delete(store.codeIndex, stored.CodeHash)
	}
	remaining := store.hostCounts[stored.Host] - 1
	if remaining <= 0 {
		delete(store.hostCounts, stored.Host)
	} else {
		store.hostCounts[stored.Host] = remaining
	}
}

// Every stored rendezvous owns exactly one indexed heap entry. Removing an
// entry on completion or disconnect keeps this index bounded by live state,
// even when rendezvous IDs are repeatedly reused before their original expiry.
type rendezvousExpiry struct {
	id        RendezvousID
	expiresAt time.Time
	index     int
}

type rendezvousExpiryHeap []*rendezvousExpiry

func (expirations rendezvousExpiryHeap) Len() int { return len(expirations) }

func (expirations rendezvousExpiryHeap) Less(left, right int) bool {
	return expirations[left].expiresAt.Before(expirations[right].expiresAt)
}

func (expirations rendezvousExpiryHeap) Swap(left, right int) {
	expirations[left], expirations[right] = expirations[right], expirations[left]
	expirations[left].index = left
	expirations[right].index = right
}

func (expirations *rendezvousExpiryHeap) Push(value any) {
	expiry := value.(*rendezvousExpiry)
	expiry.index = len(*expirations)
	*expirations = append(*expirations, expiry)
}

func (expirations *rendezvousExpiryHeap) Pop() any {
	last := len(*expirations) - 1
	expiry := (*expirations)[last]
	(*expirations)[last] = nil
	*expirations = (*expirations)[:last]
	expiry.index = -1
	return expiry
}

func (store *RendezvousStore) indexMemberLocked(deviceID DeviceID, id RendezvousID) {
	ids := store.memberIndex[deviceID]
	if ids == nil {
		ids = make(map[RendezvousID]struct{})
		store.memberIndex[deviceID] = ids
	}
	ids[id] = struct{}{}
}

func (store *RendezvousStore) removeMemberIndexLocked(deviceID DeviceID, id RendezvousID) {
	ids := store.memberIndex[deviceID]
	delete(ids, id)
	if len(ids) == 0 {
		delete(store.memberIndex, deviceID)
	}
}

func pairingCodeHash(pairingCode string) [sha256.Size]byte {
	normalized := strings.ToUpper(strings.TrimSpace(pairingCode))
	return sha256.Sum256([]byte("roammand-pairing-code:" + normalized))
}

func cloneRendezvous(rendezvous Rendezvous) Rendezvous {
	if rendezvous.Controller == nil {
		return rendezvous
	}
	controller := *rendezvous.Controller
	rendezvous.Controller = &controller
	return rendezvous
}

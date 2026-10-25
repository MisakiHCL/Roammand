// SPDX-License-Identifier: AGPL-3.0-only

package state

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

const (
	testMaxRendezvousPerHost = 8
	testMaxRendezvous        = 64
)

func TestRendezvousCodeJoinStoresOnlyHash(t *testing.T) {
	store := newTestRendezvousStore(testMaxRendezvousPerHost)
	now := time.Unix(100, 0)
	created := Rendezvous{
		ID:        testRendezvousID(1),
		Kind:      PairingKindDesktopCode,
		Host:      testDeviceID(1),
		ExpiresAt: now.Add(2 * time.Minute),
	}

	if _, err := store.Create(created, "ABCDEFGH", now); err != nil {
		t.Fatal(err)
	}
	joined, err := store.JoinByCode("abcdefgh", testDeviceID(2), now)
	if err != nil {
		t.Fatal(err)
	}
	if joined.Controller == nil || *joined.Controller != testDeviceID(2) {
		t.Fatalf("controller = %v, want device 2", joined.Controller)
	}
	store.mu.RLock()
	snapshot := fmt.Sprintf("%+v", store.byID)
	store.mu.RUnlock()
	if strings.Contains(snapshot, "ABCDEFGH") {
		t.Fatal("rendezvous state retained plaintext pairing code")
	}
}

func TestRendezvousExpiresAfterExactlyTwoMinutes(t *testing.T) {
	store := newTestRendezvousStore(testMaxRendezvousPerHost)
	now := time.Unix(100, 0)
	rendezvous := Rendezvous{
		ID:        testRendezvousID(2),
		Kind:      PairingKindQR,
		Host:      testDeviceID(1),
		ExpiresAt: now.Add(2 * time.Minute),
	}

	if _, err := store.Create(rendezvous, "", now); err != nil {
		t.Fatal(err)
	}
	removed := store.Sweep(now.Add(2 * time.Minute))
	if len(removed) != 1 || removed[0].ID != rendezvous.ID {
		t.Fatalf("removed = %+v, want rendezvous 2", removed)
	}
	if store.Len() != 0 {
		t.Fatalf("store length = %d, want 0", store.Len())
	}
}

func TestExpiredLookupLeavesRendezvousForSweepNotification(t *testing.T) {
	store := newTestRendezvousStore(testMaxRendezvousPerHost)
	now := time.Unix(100, 0)
	rendezvous := Rendezvous{
		ID:        testRendezvousID(24),
		Kind:      PairingKindQR,
		Host:      testDeviceID(1),
		ExpiresAt: now.Add(time.Second),
	}
	if _, err := store.Create(rendezvous, "", now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.JoinByID(rendezvous.ID, testDeviceID(2), now); err != nil {
		t.Fatal(err)
	}

	expiresAt := now.Add(time.Second)
	if _, _, err := store.Peer(rendezvous.ID, rendezvous.Host, expiresAt); !errors.Is(err, ErrRendezvousNotFound) {
		t.Fatalf("expired peer lookup error = %v, want %v", err, ErrRendezvousNotFound)
	}
	if store.Len() != 1 {
		t.Fatal("expired lookup removed rendezvous before the notifying sweep")
	}
	removed := store.Sweep(expiresAt)
	if len(removed) != 1 || removed[0].ID != rendezvous.ID || store.Len() != 0 {
		t.Fatalf("sweep removed=%+v remaining=%d", removed, store.Len())
	}
}

func TestRendezvousAllowsOneDistinctController(t *testing.T) {
	store := newTestRendezvousStore(testMaxRendezvousPerHost)
	now := time.Unix(100, 0)
	id := testRendezvousID(3)
	host := testDeviceID(1)
	if _, err := store.Create(Rendezvous{
		ID: id, Kind: PairingKindQR, Host: host, ExpiresAt: now.Add(time.Minute),
	}, "", now); err != nil {
		t.Fatal(err)
	}

	if _, err := store.JoinByID(id, host, now); !errors.Is(err, ErrRendezvousSelfJoin) {
		t.Fatalf("self join error = %v, want %v", err, ErrRendezvousSelfJoin)
	}
	if _, err := store.JoinByID(id, testDeviceID(2), now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.JoinByID(id, testDeviceID(3), now); !errors.Is(err, ErrRendezvousFull) {
		t.Fatalf("second controller error = %v, want %v", err, ErrRendezvousFull)
	}
}

func TestRendezvousPeerAndHostOnlyCompletion(t *testing.T) {
	store := newTestRendezvousStore(testMaxRendezvousPerHost)
	now := time.Unix(100, 0)
	id := testRendezvousID(4)
	host := testDeviceID(1)
	controller := testDeviceID(2)
	if _, err := store.Create(Rendezvous{
		ID: id, Kind: PairingKindQR, Host: host, ExpiresAt: now.Add(time.Minute),
	}, "", now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.JoinByID(id, controller, now); err != nil {
		t.Fatal(err)
	}

	peer, _, err := store.Peer(id, host, now)
	if err != nil || peer != controller {
		t.Fatalf("host peer = (%v, %v), want controller", peer, err)
	}
	peer, _, err = store.Peer(id, controller, now)
	if err != nil || peer != host {
		t.Fatalf("controller peer = (%v, %v), want host", peer, err)
	}
	if _, _, err := store.Peer(id, testDeviceID(3), now); !errors.Is(err, ErrRendezvousNotMember) {
		t.Fatalf("non-member error = %v, want %v", err, ErrRendezvousNotMember)
	}
	if _, err := store.Complete(id, controller, now); !errors.Is(err, ErrRendezvousNotHost) {
		t.Fatalf("controller completion error = %v, want %v", err, ErrRendezvousNotHost)
	}
	if _, err := store.Complete(id, host, now); err != nil {
		t.Fatal(err)
	}
	if store.Len() != 0 {
		t.Fatalf("store length = %d, want 0 after completion", store.Len())
	}
}

func TestRendezvousDisconnectRemovesMemberSessions(t *testing.T) {
	store := newTestRendezvousStore(testMaxRendezvousPerHost)
	now := time.Unix(100, 0)
	host := testDeviceID(1)
	controller := testDeviceID(2)
	for seed := byte(5); seed < 7; seed++ {
		id := testRendezvousID(seed)
		if _, err := store.Create(Rendezvous{
			ID: id, Kind: PairingKindQR, Host: host, ExpiresAt: now.Add(time.Minute),
		}, "", now); err != nil {
			t.Fatal(err)
		}
		if _, err := store.JoinByID(id, controller, now); err != nil {
			t.Fatal(err)
		}
	}

	removed := store.RemoveForDevice(controller)
	if len(removed) != 2 || store.Len() != 0 {
		t.Fatalf("removed=%d remaining=%d, want 2 and 0", len(removed), store.Len())
	}
}

func TestRendezvousLimitsActiveEntriesPerHostAndReleasesCapacity(t *testing.T) {
	const maxPerHost = 2
	store := newTestRendezvousStore(maxPerHost)
	now := time.Unix(100, 0)
	host := testDeviceID(1)
	otherHost := testDeviceID(2)

	create := func(idSeed byte, owner DeviceID) error {
		_, err := store.Create(Rendezvous{
			ID:        testRendezvousID(idSeed),
			Kind:      PairingKindQR,
			Host:      owner,
			ExpiresAt: now.Add(time.Minute),
		}, "", now)
		return err
	}
	if err := create(10, host); err != nil {
		t.Fatal(err)
	}
	if err := create(11, host); err != nil {
		t.Fatal(err)
	}
	if err := create(12, host); !errors.Is(err, ErrRendezvousLimit) {
		t.Fatalf("third rendezvous error = %v, want %v", err, ErrRendezvousLimit)
	}
	if err := create(13, otherHost); err != nil {
		t.Fatalf("other host was affected by limit: %v", err)
	}

	if _, err := store.Complete(testRendezvousID(10), host, now); err != nil {
		t.Fatal(err)
	}
	if err := create(12, host); err != nil {
		t.Fatalf("released capacity was not reusable: %v", err)
	}
}

func TestRendezvousLimitsGlobalEntriesAndReleasesCapacity(t *testing.T) {
	const maxTotal = 2
	store := NewRendezvousStore(testMaxRendezvousPerHost, maxTotal)
	now := time.Unix(100, 0)
	create := func(idSeed byte, hostSeed byte) error {
		_, err := store.Create(Rendezvous{
			ID:        testRendezvousID(idSeed),
			Kind:      PairingKindQR,
			Host:      testDeviceID(hostSeed),
			ExpiresAt: now.Add(time.Minute),
		}, "", now)
		return err
	}
	if err := create(14, 1); err != nil {
		t.Fatal(err)
	}
	if err := create(15, 2); err != nil {
		t.Fatal(err)
	}
	if err := create(16, 3); !errors.Is(err, ErrRendezvousCapacity) {
		t.Fatalf("capacity error = %v, want %v", err, ErrRendezvousCapacity)
	}
	if _, err := store.Complete(testRendezvousID(14), testDeviceID(1), now); err != nil {
		t.Fatal(err)
	}
	if err := create(16, 3); err != nil {
		t.Fatalf("released global capacity was not reusable: %v", err)
	}
}

func TestRendezvousMemberIndexRemovesOnlyMatchingDevice(t *testing.T) {
	store := newTestRendezvousStore(testMaxRendezvousPerHost)
	now := time.Unix(100, 0)
	for seed := byte(30); seed < 32; seed++ {
		if _, err := store.Create(Rendezvous{
			ID:        testRendezvousID(seed),
			Kind:      PairingKindQR,
			Host:      testDeviceID(seed),
			ExpiresAt: now.Add(time.Minute),
		}, "", now); err != nil {
			t.Fatal(err)
		}
		if _, err := store.JoinByID(testRendezvousID(seed), testDeviceID(seed+10), now); err != nil {
			t.Fatal(err)
		}
	}

	removed := store.RemoveForDevice(testDeviceID(40))
	if len(removed) != 1 || removed[0].ID != testRendezvousID(30) || store.Len() != 1 {
		t.Fatalf("removed=%+v remaining=%d", removed, store.Len())
	}
	if _, _, err := store.Peer(
		testRendezvousID(31),
		testDeviceID(31),
		now,
	); err != nil {
		t.Fatalf("unrelated rendezvous was removed: %v", err)
	}
}

func TestRendezvousCreateReleasesExpiredHostCapacityImmediately(t *testing.T) {
	store := newTestRendezvousStore(1)
	now := time.Unix(100, 0)
	host := testDeviceID(1)
	if _, err := store.Create(Rendezvous{
		ID:        testRendezvousID(20),
		Kind:      PairingKindQR,
		Host:      host,
		ExpiresAt: now.Add(time.Second),
	}, "", now); err != nil {
		t.Fatal(err)
	}

	later := now.Add(time.Second)
	removed, err := store.Create(Rendezvous{
		ID:        testRendezvousID(21),
		Kind:      PairingKindQR,
		Host:      host,
		ExpiresAt: later.Add(time.Minute),
	}, "", later)
	if err != nil {
		t.Fatalf("expired rendezvous still consumed host capacity: %v", err)
	}
	if len(removed) != 1 || removed[0].ID != testRendezvousID(20) {
		t.Fatalf("removed = %+v, want expired rendezvous 20", removed)
	}
	if store.Len() != 1 {
		t.Fatalf("store length = %d, want 1", store.Len())
	}
}

func TestRendezvousCreateReusesAnExpiredDesktopCode(t *testing.T) {
	store := newTestRendezvousStore(2)
	now := time.Unix(100, 0)
	if _, err := store.Create(Rendezvous{
		ID:        testRendezvousID(22),
		Kind:      PairingKindDesktopCode,
		Host:      testDeviceID(1),
		ExpiresAt: now.Add(time.Second),
	}, "ABCDEFGH", now); err != nil {
		t.Fatal(err)
	}

	later := now.Add(time.Second)
	removed, err := store.Create(Rendezvous{
		ID:        testRendezvousID(23),
		Kind:      PairingKindDesktopCode,
		Host:      testDeviceID(2),
		ExpiresAt: later.Add(time.Minute),
	}, "ABCDEFGH", later)
	if err != nil {
		t.Fatalf("expired desktop code was not reusable: %v", err)
	}
	if len(removed) != 1 || removed[0].ID != testRendezvousID(22) {
		t.Fatalf("removed = %+v, want expired rendezvous 22", removed)
	}
}

func TestRendezvousExpiryIndexHandlesMixedDeadlinesAndRemoval(t *testing.T) {
	store := newTestRendezvousStore(testMaxRendezvousPerHost)
	now := time.Unix(100, 0)
	deadlines := []time.Duration{5, 1, 3, 1, 5, 2, 4, 1}
	controller := testDeviceID(100)
	for index, seconds := range deadlines {
		seed := byte(index + 1)
		if _, err := store.Create(Rendezvous{
			ID:        testRendezvousID(seed),
			Kind:      PairingKindDesktopCode,
			Host:      testDeviceID(seed),
			ExpiresAt: now.Add(seconds * time.Second),
		}, "AAAAAAA"+string(rune('A'+index)), now); err != nil {
			t.Fatal(err)
		}
		if index == 5 || index == 6 {
			if _, err := store.JoinByID(testRendezvousID(seed), controller, now); err != nil {
				t.Fatal(err)
			}
		}
		assertRendezvousIndexes(t, store)
	}
	// Remove both an earliest deadline and an interior heap entry, followed by
	// multiple entries owned by a controller with different deadlines.
	for _, seed := range []byte{2, 3} {
		if _, err := store.Complete(testRendezvousID(seed), testDeviceID(seed), now); err != nil {
			t.Fatal(err)
		}
		assertRendezvousIndexes(t, store)
	}
	if removed := store.RemoveForDevice(controller); len(removed) != 2 {
		t.Fatalf("disconnect removed %d rendezvous, want 2", len(removed))
	}
	assertRendezvousIndexes(t, store)

	assertRemovedIDs := func(at time.Time, seeds ...byte) {
		t.Helper()
		removed := store.Sweep(at)
		wanted := make(map[RendezvousID]bool, len(seeds))
		for _, seed := range seeds {
			wanted[testRendezvousID(seed)] = true
		}
		if len(removed) != len(wanted) {
			t.Fatalf("removed at %v = %+v, want seeds %v", at, removed, seeds)
		}
		for _, rendezvous := range removed {
			if !wanted[rendezvous.ID] {
				t.Fatalf("unexpected or duplicate expired rendezvous: %+v", rendezvous)
			}
			delete(wanted, rendezvous.ID)
		}
		assertRendezvousIndexes(t, store)
	}
	assertRemovedIDs(now.Add(time.Second), 4, 8)
	assertRemovedIDs(now.Add(4 * time.Second))
	assertRemovedIDs(now.Add(5*time.Second), 1, 5)
	assertRemovedIDs(now.Add(time.Hour))
}

func TestRendezvousIDReuseDoesNotInheritRemovedExpiry(t *testing.T) {
	for _, remove := range []string{"complete", "disconnect", "expire"} {
		t.Run(remove, func(t *testing.T) {
			store := NewRendezvousStore(1, 1)
			now := time.Unix(100, 0)
			host := testDeviceID(1)
			id := testRendezvousID(1)
			oldExpiry := now.Add(time.Minute)
			if _, err := store.Create(Rendezvous{
				ID: id, Kind: PairingKindDesktopCode, Host: host, ExpiresAt: oldExpiry,
			}, "ABCDEFGH", now); err != nil {
				t.Fatal(err)
			}
			createAt := now
			switch remove {
			case "complete":
				if _, err := store.Complete(id, host, now); err != nil {
					t.Fatal(err)
				}
			case "disconnect":
				if removed := store.RemoveForDevice(host); len(removed) != 1 {
					t.Fatalf("disconnect removed %d rendezvous, want 1", len(removed))
				}
			case "expire":
				// Create itself must free both the full global and host capacity,
				// as well as the old ID and pairing code, without a separate sweep.
				createAt = oldExpiry
			}
			removed, err := store.Create(Rendezvous{
				ID: id, Kind: PairingKindDesktopCode, Host: host,
				ExpiresAt: oldExpiry.Add(time.Minute),
			}, "ABCDEFGH", createAt)
			if err != nil {
				t.Fatal(err)
			}
			if (remove == "expire" && len(removed) != 1) || (remove != "expire" && len(removed) != 0) {
				t.Fatalf("Create removed %d rendezvous after %s", len(removed), remove)
			}
			assertRendezvousIndexes(t, store)
			if removed := store.Sweep(oldExpiry); len(removed) != 0 || store.Len() != 1 {
				t.Fatalf("old expiry removed replacement: removed=%+v remaining=%d", removed, store.Len())
			}
			if _, err := store.JoinByCode("ABCDEFGH", testDeviceID(2), oldExpiry); err != nil {
				t.Fatalf("replacement pairing code unavailable: %v", err)
			}
			assertRendezvousIndexes(t, store)
			if removed := store.Sweep(oldExpiry.Add(time.Minute)); len(removed) != 1 || removed[0].Controller == nil {
				t.Fatalf("replacement expiration lost notification state: %+v", removed)
			}
			assertRendezvousIndexes(t, store)
		})
	}
}

func TestRendezvousCreateFailureStillReturnsExpiredNotifications(t *testing.T) {
	store := NewRendezvousStore(1, 2)
	now := time.Unix(100, 0)
	old := Rendezvous{
		ID: testRendezvousID(1), Kind: PairingKindDesktopCode,
		Host: testDeviceID(1), ExpiresAt: now.Add(time.Second),
	}
	active := Rendezvous{
		ID: testRendezvousID(2), Kind: PairingKindQR,
		Host: testDeviceID(2), ExpiresAt: now.Add(time.Minute),
	}
	if _, err := store.Create(old, "ABCDEFGH", now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.JoinByID(old.ID, testDeviceID(3), now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Create(active, "", now); err != nil {
		t.Fatal(err)
	}
	removed, err := store.Create(active, "", old.ExpiresAt)
	if !errors.Is(err, ErrRendezvousExists) || len(removed) != 1 || removed[0].ID != old.ID || removed[0].Controller == nil {
		t.Fatalf("duplicate create error=%v removed=%+v, want expiry notification", err, removed)
	}
	assertRendezvousIndexes(t, store)
	if _, err := store.JoinByCode("ABCDEFGH", testDeviceID(4), old.ExpiresAt); !errors.Is(err, ErrRendezvousNotFound) {
		t.Fatalf("expired code remained indexed: %v", err)
	}
	old.ExpiresAt = now.Add(time.Minute)
	if _, err := store.Create(old, "ABCDEFGH", now.Add(time.Second)); err != nil {
		t.Fatalf("expired capacity or code was not released: %v", err)
	}
	assertRendezvousIndexes(t, store)
}

func TestRendezvousExpiryIndexStaysBoundedDuringChurn(t *testing.T) {
	store := NewRendezvousStore(1, 2)
	now := time.Unix(100, 0)
	anchor := Rendezvous{
		ID: testRendezvousID(1), Kind: PairingKindQR,
		Host: testDeviceID(1), ExpiresAt: now.Add(time.Hour),
	}
	if _, err := store.Create(anchor, "", now); err != nil {
		t.Fatal(err)
	}
	for iteration := 0; iteration < 1_000; iteration++ {
		rendezvous := Rendezvous{
			ID: testRendezvousID(2), Kind: PairingKindQR,
			Host: testDeviceID(2), ExpiresAt: now.Add(time.Duration(iteration+1) * time.Minute),
		}
		if _, err := store.Create(rendezvous, "", now); err != nil {
			t.Fatal(err)
		}
		assertRendezvousIndexes(t, store)
		if iteration%2 == 0 {
			if _, err := store.Complete(rendezvous.ID, rendezvous.Host, now); err != nil {
				t.Fatal(err)
			}
		} else if removed := store.RemoveForDevice(rendezvous.Host); len(removed) != 1 {
			t.Fatalf("disconnect removed %d rendezvous, want 1", len(removed))
		}
		assertRendezvousIndexes(t, store)
		if cap(store.expirations) > store.maxTotal {
			t.Fatalf("expiry storage grew beyond peak live entries: capacity=%d", cap(store.expirations))
		}
	}
	if removed := store.Sweep(anchor.ExpiresAt); len(removed) != 1 || removed[0].ID != anchor.ID {
		t.Fatalf("churn left stale expirations: %+v", removed)
	}
	assertRendezvousIndexes(t, store)
}

func assertRendezvousIndexes(t *testing.T, store *RendezvousStore) {
	t.Helper()
	store.mu.RLock()
	defer store.mu.RUnlock()
	if len(store.expirations) != len(store.byID) || len(store.expiryIndex) != len(store.byID) {
		t.Fatalf("index sizes: expirations=%d expiryIndex=%d byID=%d", len(store.expirations), len(store.expiryIndex), len(store.byID))
	}
	for index, expiry := range store.expirations {
		rendezvous, exists := store.byID[expiry.id]
		if !exists || expiry.index != index || store.expiryIndex[expiry.id] != expiry || !expiry.expiresAt.Equal(rendezvous.ExpiresAt) {
			t.Fatalf("inconsistent expiry entry at %d: %+v", index, expiry)
		}
		if index > 0 && expiry.expiresAt.Before(store.expirations[(index-1)/2].expiresAt) {
			t.Fatalf("earlier deadline below its parent at index %d", index)
		}
	}
	// Removed heap slots must release their pointers even when the backing
	// allocation is reused by future requests.
	for _, expiry := range store.expirations[len(store.expirations):cap(store.expirations)] {
		if expiry != nil {
			t.Fatalf("removed expiry retained in backing storage: %+v", expiry)
		}
	}
	counts := make(map[DeviceID]int)
	codeCount := 0
	for id, rendezvous := range store.byID {
		counts[rendezvous.Host]++
		if _, exists := store.memberIndex[rendezvous.Host][id]; !exists {
			t.Fatalf("host member index missing rendezvous %v", id)
		}
		if rendezvous.Controller != nil {
			if _, exists := store.memberIndex[*rendezvous.Controller][id]; !exists {
				t.Fatalf("controller member index missing rendezvous %v", id)
			}
		}
		if rendezvous.Kind == PairingKindDesktopCode {
			codeCount++
			if store.codeIndex[rendezvous.CodeHash] != id {
				t.Fatalf("pairing code index missing rendezvous %v", id)
			}
		}
	}
	if len(store.hostCounts) != len(counts) || len(store.codeIndex) != codeCount {
		t.Fatalf("stale count/code indexes: hostCounts=%v codeIndex=%v", store.hostCounts, store.codeIndex)
	}
	for host, count := range counts {
		if store.hostCounts[host] != count {
			t.Fatalf("host %v count=%d, want %d", host, store.hostCounts[host], count)
		}
	}
	for member, ids := range store.memberIndex {
		if len(ids) == 0 {
			t.Fatalf("empty member index retained for %v", member)
		}
		for id := range ids {
			rendezvous, exists := store.byID[id]
			if !exists || (rendezvous.Host != member && (rendezvous.Controller == nil || *rendezvous.Controller != member)) {
				t.Fatalf("stale member index for %v: %v", member, id)
			}
		}
	}
}

func testRendezvousID(seed byte) RendezvousID {
	var id RendezvousID
	for index := range id {
		id[index] = seed
	}
	return id
}

func newTestRendezvousStore(maxPerHost int) *RendezvousStore {
	return NewRendezvousStore(maxPerHost, testMaxRendezvous)
}

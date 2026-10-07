// SPDX-License-Identifier: AGPL-3.0-only

package state

import (
	"testing"
	"time"
)

func TestPresenceFirstLiveRegistrationWins(t *testing.T) {
	registry := NewPresenceRegistry()
	id := testDeviceID(1)
	now := time.Unix(100, 0)

	if !registry.Register(id, Route{Token: 1}, now) {
		t.Fatal("first registration was rejected")
	}
	if registry.Register(id, Route{Token: 2}, now) {
		t.Fatal("duplicate live registration was accepted")
	}

	got, ok := registry.Lookup(id)
	if !ok || got.Token != 1 {
		t.Fatalf("lookup = (%+v, %v), want token 1", got, ok)
	}
}

func TestPresenceRemovalDoesNotDeleteReplacement(t *testing.T) {
	registry := NewPresenceRegistry()
	id := testDeviceID(2)
	now := time.Unix(100, 0)

	if !registry.Register(id, Route{Token: 1}, now) {
		t.Fatal("first registration was rejected")
	}
	if !registry.Remove(id, 1) {
		t.Fatal("first route was not removed")
	}
	if !registry.Register(id, Route{Token: 2}, now) {
		t.Fatal("replacement registration was rejected")
	}
	if registry.Remove(id, 1) {
		t.Fatal("stale token removed replacement route")
	}

	got, ok := registry.Lookup(id)
	if !ok || got.Token != 2 {
		t.Fatalf("lookup = (%+v, %v), want token 2", got, ok)
	}
}

func TestPresenceTouchAndExpiry(t *testing.T) {
	registry := NewPresenceRegistry()
	id := testDeviceID(3)
	now := time.Unix(100, 0)

	if !registry.Register(id, Route{Token: 3}, now) {
		t.Fatal("registration was rejected")
	}
	if registry.Touch(id, 99, now.Add(10*time.Second)) {
		t.Fatal("stale token refreshed route")
	}
	refreshedAt := now.Add(30 * time.Second)
	if !registry.Touch(id, 3, refreshedAt) {
		t.Fatal("active route was not refreshed")
	}
	if expired := registry.ExpiredBefore(refreshedAt); len(expired) != 0 {
		t.Fatalf("expired %d routes at the exact last-seen boundary", len(expired))
	}

	expired := registry.ExpiredBefore(refreshedAt.Add(time.Nanosecond))
	if len(expired) != 1 || expired[0].Token != 3 {
		t.Fatalf("expired routes = %+v, want token 3", expired)
	}
	if registry.Len() != 1 {
		t.Fatalf("registry length = %d, want stale route reserved until cleanup", registry.Len())
	}
}

func TestPresenceReconnectAfterCleanup(t *testing.T) {
	registry := NewPresenceRegistry()
	id := testDeviceID(4)
	now := time.Unix(100, 0)

	if !registry.Register(id, Route{Token: 1}, now) {
		t.Fatal("first registration was rejected")
	}
	registry.ExpiredBefore(now.Add(time.Nanosecond))
	if registry.Register(id, Route{Token: 2}, now.Add(time.Second)) {
		t.Fatal("reconnect was accepted before expired connection cleanup")
	}
	if !registry.Remove(id, 1) {
		t.Fatal("expired connection cleanup did not release its route")
	}
	if !registry.Register(id, Route{Token: 2}, now.Add(time.Second)) {
		t.Fatal("reconnect was rejected after expiry cleanup")
	}
}

func testDeviceID(seed byte) DeviceID {
	var id DeviceID
	for index := range id {
		id[index] = seed
	}
	return id
}

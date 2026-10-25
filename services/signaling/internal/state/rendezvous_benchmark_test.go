// SPDX-License-Identifier: AGPL-3.0-only

package state

import (
	"encoding/binary"
	"errors"
	"fmt"
	"testing"
	"time"
)

func BenchmarkRendezvousCreateAtLivePopulation(b *testing.B) {
	for _, population := range []int{64, 4_096, 65_536} {
		b.Run(fmt.Sprint(population), func(b *testing.B) {
			now := time.Unix(100, 0)
			store := NewRendezvousStore(1, population+1)
			for index := 0; index < population; index++ {
				var id RendezvousID
				var host DeviceID
				binary.LittleEndian.PutUint64(id[:], uint64(index))
				binary.LittleEndian.PutUint64(host[:], uint64(index))
				if _, err := store.Create(Rendezvous{
					ID: id, Kind: PairingKindQR, Host: host, ExpiresAt: now.Add(time.Minute),
				}, "", now); err != nil {
					b.Fatal(err)
				}
			}
			duplicate := Rendezvous{Kind: PairingKindQR, ExpiresAt: now.Add(time.Minute)}
			b.Run("duplicate", func(b *testing.B) {
				b.ReportAllocs()
				for index := 0; index < b.N; index++ {
					if _, err := store.Create(duplicate, "", now); !errors.Is(err, ErrRendezvousExists) {
						b.Fatal(err)
					}
				}
			})
			b.Run("replace", func(b *testing.B) {
				b.ReportAllocs()
				for index := 0; index < b.N; index++ {
					if _, err := store.Complete(duplicate.ID, duplicate.Host, now); err != nil {
						b.Fatal(err)
					}
					if _, err := store.Create(duplicate, "", now); err != nil {
						b.Fatal(err)
					}
				}
			})
		})
	}
}

// SPDX-License-Identifier: AGPL-3.0-only

package service

import (
	"bytes"
	"testing"
	"time"

	roammandv1 "github.com/MisakiHCL/roammand/gen/go/roammand/v1"
	"github.com/MisakiHCL/roammand/services/signaling/internal/state"
	"github.com/coder/websocket"
)

func TestPairingRendezvousLifecycleAndOpaqueRelay(t *testing.T) {
	clock := newTestClock(time.Unix(100, 0))
	options := DefaultOptions()
	options.Now = clock.Now
	options.SweepInterval = time.Hour
	testServer := newServiceTestServer(t, options)
	host := testServer.dial(t)
	controller := testServer.dial(t)
	hostID := testDeviceBytes(10)
	controllerID := testDeviceBytes(11)
	rendezvousID := testRendezvousBytes(1)
	registerClient(t, host, hostID, "register-host")
	registerClient(t, controller, controllerID, "register-controller")

	createRendezvous(t, host, rendezvousID, roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR, "")
	created := readServerFrame(t, host).GetRendezvousCreated()
	if created == nil || created.GetExpiresAtUnixMs() != uint64(clock.Now().Add(2*time.Minute).UnixMilli()) {
		t.Fatalf("created = %+v", created)
	}
	joinRendezvousByID(t, controller, rendezvousID, "join-controller")
	controllerJoined := readServerFrame(t, controller).GetRendezvousJoined()
	hostJoined := readServerFrame(t, host).GetRendezvousJoined()
	if controllerJoined == nil || !bytes.Equal(controllerJoined.GetPeerDeviceId(), hostID) {
		t.Fatalf("controller joined = %+v", controllerJoined)
	}
	if hostJoined == nil || !bytes.Equal(hostJoined.GetPeerDeviceId(), controllerID) {
		t.Fatalf("host joined = %+v", hostJoined)
	}

	hostOpaque := []byte{0xff, 0x00, 0x7f, 0x01}
	relayPairing(t, host, rendezvousID, hostOpaque, "relay-host")
	assertRoutedPairing(t, readServerFrame(t, controller), hostID, hostOpaque)
	controllerOpaque := []byte("not a protobuf envelope")
	relayPairing(t, controller, rendezvousID, controllerOpaque, "relay-controller")
	assertRoutedPairing(t, readServerFrame(t, host), controllerID, controllerOpaque)

	completeRendezvous(t, controller, rendezvousID, "complete-controller")
	if got := readServerFrame(t, controller).GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_PAIRING_REJECTED {
		t.Fatalf("controller completion code = %v", got)
	}
	completeRendezvous(t, host, rendezvousID, "complete-host")
	hostClosed := readServerFrame(t, host).GetRendezvousClosed()
	controllerClosed := readServerFrame(t, controller).GetRendezvousClosed()
	for _, closed := range []*roammandv1.PairingRendezvousClosed{hostClosed, controllerClosed} {
		if closed == nil || closed.GetCompletion() != roammandv1.PairingRendezvousCompletion_PAIRING_RENDEZVOUS_COMPLETION_SUCCEEDED {
			t.Fatalf("closed = %+v", closed)
		}
	}

	relayPairing(t, controller, rendezvousID, []byte{1}, "relay-after-complete")
	if got := readServerFrame(t, controller).GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_PAIRING_CODE_EXPIRED {
		t.Fatalf("post-completion code = %v", got)
	}
}

func TestDesktopPairingCodeJoinIsCaseInsensitive(t *testing.T) {
	testServer := newServiceTestServer(t, DefaultOptions())
	host := testServer.dial(t)
	controller := testServer.dial(t)
	registerClient(t, host, testDeviceBytes(12), "register-host")
	registerClient(t, controller, testDeviceBytes(13), "register-controller")
	rendezvousID := testRendezvousBytes(2)
	createRendezvous(
		t,
		host,
		rendezvousID,
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_DESKTOP_CODE,
		"ABCDEFGH",
	)
	_ = readServerFrame(t, host)
	writeClientFrame(t, controller, &roammandv1.SignalingClientFrame{
		ProtocolVersion: protocolVersion(),
		RequestId:       "join-code",
		Payload: &roammandv1.SignalingClientFrame_JoinRendezvous{
			JoinRendezvous: &roammandv1.JoinPairingRendezvous{
				Lookup: &roammandv1.JoinPairingRendezvous_PairingCode{PairingCode: "abcdefgh"},
			},
		},
	})
	if joined := readServerFrame(t, controller).GetRendezvousJoined(); joined == nil {
		t.Fatal("desktop code join failed")
	}
}

func TestPairingLimitsActiveRendezvousPerHostAndReleasesCapacity(t *testing.T) {
	options := DefaultOptions()
	options.MaxRendezvousPerHost = 1
	testServer := newServiceTestServer(t, options)
	host := testServer.dial(t)
	registerClient(t, host, testDeviceBytes(30), "register-host")
	firstID := testRendezvousBytes(30)
	secondID := testRendezvousBytes(31)

	createRendezvous(
		t,
		host,
		firstID,
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	if created := readServerFrame(t, host).GetRendezvousCreated(); created == nil {
		t.Fatal("first rendezvous creation response missing")
	}
	createRendezvous(
		t,
		host,
		secondID,
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	assertPairingRejected(t, readServerFrame(t, host))

	completeRendezvous(t, host, firstID, "complete-first")
	if closed := readServerFrame(t, host).GetRendezvousClosed(); closed == nil {
		t.Fatal("first rendezvous completion response missing")
	}
	createRendezvous(
		t,
		host,
		secondID,
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	if created := readServerFrame(t, host).GetRendezvousCreated(); created == nil {
		t.Fatal("released rendezvous capacity was not reusable")
	}
}

func TestPairingLimitsGlobalRendezvousAndReleasesCapacity(t *testing.T) {
	options := DefaultOptions()
	options.MaxRendezvous = 1
	testServer := newServiceTestServer(t, options)
	firstHost := testServer.dial(t)
	secondHost := testServer.dial(t)
	registerClient(t, firstHost, testDeviceBytes(32), "register-first-host")
	registerClient(t, secondHost, testDeviceBytes(33), "register-second-host")
	firstID := testRendezvousBytes(32)
	secondID := testRendezvousBytes(33)

	createRendezvous(
		t,
		firstHost,
		firstID,
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	if created := readServerFrame(t, firstHost).GetRendezvousCreated(); created == nil {
		t.Fatal("first rendezvous creation response missing")
	}
	createRendezvous(
		t,
		secondHost,
		secondID,
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	if got := readServerFrame(t, secondHost).GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE {
		t.Fatalf("global capacity error = %v", got)
	}

	completeRendezvous(t, firstHost, firstID, "complete-first")
	if closed := readServerFrame(t, firstHost).GetRendezvousClosed(); closed == nil {
		t.Fatal("first rendezvous completion response missing")
	}
	createRendezvous(
		t,
		secondHost,
		secondID,
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	if created := readServerFrame(t, secondHost).GetRendezvousCreated(); created == nil {
		t.Fatal("released global rendezvous capacity was not reusable")
	}
}

func TestCreateReleasesExpiredCapacityAndNotifiesBothMembers(t *testing.T) {
	clock := newTestClock(time.Unix(100, 0))
	options := DefaultOptions()
	options.Now = clock.Now
	options.MaxRendezvousPerHost = 1
	options.SweepInterval = time.Hour
	testServer := newServiceTestServer(t, options)
	host := testServer.dial(t)
	controller := testServer.dial(t)
	registerClient(t, host, testDeviceBytes(36), "register-host")
	registerClient(t, controller, testDeviceBytes(37), "register-controller")
	createAndJoinQR(t, host, controller, testRendezvousBytes(36))

	clock.Advance(options.RendezvousTTL)
	createRendezvous(
		t,
		host,
		testRendezvousBytes(37),
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	hostClosed := readServerFrame(t, host).GetRendezvousClosed()
	controllerClosed := readServerFrame(t, controller).GetRendezvousClosed()
	for _, closed := range []*roammandv1.PairingRendezvousClosed{
		hostClosed,
		controllerClosed,
	} {
		if closed == nil ||
			closed.GetCompletion() != roammandv1.PairingRendezvousCompletion_PAIRING_RENDEZVOUS_COMPLETION_EXPIRED {
			t.Fatalf("expiry notification = %+v", closed)
		}
	}
	if created := readServerFrame(t, host).GetRendezvousCreated(); created == nil {
		t.Fatal("replacement rendezvous creation response missing")
	}
}

func TestPairingRateLimitReturnsRetryAfter(t *testing.T) {
	options := DefaultOptions()
	options.PairingAttemptsPerIP = 100
	options.PairingAttemptsPerLookupKey = 1
	testServer := newServiceTestServer(t, options)
	controller := testServer.dial(t)
	registerClient(t, controller, testDeviceBytes(14), "register-controller")

	joinRendezvousByCode(t, controller, "ZZZZZZZZ", "join-missing-1")
	if got := readServerFrame(t, controller).GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_PAIRING_CODE_EXPIRED {
		t.Fatalf("first missing code = %v", got)
	}
	joinRendezvousByCode(t, controller, "ZZZZZZZZ", "join-missing-2")
	protocolError := readServerFrame(t, controller).GetError()
	if protocolError.GetCode() != roammandv1.ErrorCode_ERROR_CODE_PAIRING_RATE_LIMITED ||
		protocolError.GetRetryAfter().GetRetryAfterMs() == 0 {
		t.Fatalf("rate limit error = %+v", protocolError)
	}
}

func TestCreateRendezvousUsesSharedPairingIPLimit(t *testing.T) {
	options := DefaultOptions()
	options.PairingAttemptsPerIP = 1
	options.PairingAttemptsPerLookupKey = 100
	testServer := newServiceTestServer(t, options)
	host := testServer.dial(t)
	registerClient(t, host, testDeviceBytes(34), "register-host")

	createRendezvous(
		t,
		host,
		testRendezvousBytes(34),
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	if created := readServerFrame(t, host).GetRendezvousCreated(); created == nil {
		t.Fatal("first create was rejected")
	}
	createRendezvous(
		t,
		host,
		testRendezvousBytes(35),
		roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR,
		"",
	)
	protocolError := readServerFrame(t, host).GetError()
	if protocolError.GetCode() != roammandv1.ErrorCode_ERROR_CODE_PAIRING_RATE_LIMITED ||
		protocolError.GetRetryAfter().GetRetryAfterMs() == 0 {
		t.Fatalf("create rate limit error = %+v", protocolError)
	}
}

func TestPairingRejectsSelfJoinSecondControllerAndNonMemberRelay(t *testing.T) {
	testServer := newServiceTestServer(t, DefaultOptions())
	host := testServer.dial(t)
	firstController := testServer.dial(t)
	secondController := testServer.dial(t)
	hostID := testDeviceBytes(15)
	rendezvousID := testRendezvousBytes(3)
	registerClient(t, host, hostID, "register-host")
	registerClient(t, firstController, testDeviceBytes(16), "register-controller-1")
	registerClient(t, secondController, testDeviceBytes(17), "register-controller-2")
	createRendezvous(t, host, rendezvousID, roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR, "")
	_ = readServerFrame(t, host)

	joinRendezvousByID(t, host, rendezvousID, "self-join")
	assertPairingRejected(t, readServerFrame(t, host))
	joinRendezvousByID(t, firstController, rendezvousID, "join-first")
	_ = readServerFrame(t, firstController)
	_ = readServerFrame(t, host)
	joinRendezvousByID(t, secondController, rendezvousID, "join-second")
	assertPairingRejected(t, readServerFrame(t, secondController))
	relayPairing(t, secondController, rendezvousID, []byte{1}, "relay-non-member")
	assertPairingRejected(t, readServerFrame(t, secondController))
}

func TestPairingExpiryAndDisconnectNotifyMembers(t *testing.T) {
	t.Run("expiry", func(t *testing.T) {
		clock := newTestClock(time.Unix(100, 0))
		options := DefaultOptions()
		options.Now = clock.Now
		options.PresenceTimeout = 10 * time.Minute
		options.SweepInterval = time.Hour
		testServer := newServiceTestServer(t, options)
		host := testServer.dial(t)
		controller := testServer.dial(t)
		registerClient(t, host, testDeviceBytes(18), "register-host")
		registerClient(t, controller, testDeviceBytes(19), "register-controller")
		rendezvousID := testRendezvousBytes(4)
		createAndJoinQR(t, host, controller, rendezvousID)

		clock.Advance(2 * time.Minute)
		relayPairing(t, host, rendezvousID, []byte{1}, "relay-at-expiry")
		if got := readServerFrame(t, host).GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_PAIRING_CODE_EXPIRED {
			t.Fatalf("expired relay code = %v", got)
		}
		testServer.service.Sweep(clock.Now())
		for _, client := range []*websocket.Conn{host, controller} {
			closed := readServerFrame(t, client).GetRendezvousClosed()
			if closed == nil || closed.GetCompletion() != roammandv1.PairingRendezvousCompletion_PAIRING_RENDEZVOUS_COMPLETION_EXPIRED {
				t.Fatalf("expiry notification = %+v", closed)
			}
		}
	})

	t.Run("disconnect", func(t *testing.T) {
		testServer := newServiceTestServer(t, DefaultOptions())
		host := testServer.dial(t)
		controller := testServer.dial(t)
		registerClient(t, host, testDeviceBytes(20), "register-host")
		registerClient(t, controller, testDeviceBytes(21), "register-controller")
		createAndJoinQR(t, host, controller, testRendezvousBytes(5))

		_ = controller.Close(websocket.StatusNormalClosure, "")
		closed := readServerFrame(t, host).GetRendezvousClosed()
		if closed == nil || closed.GetCompletion() != roammandv1.PairingRendezvousCompletion_PAIRING_RENDEZVOUS_COMPLETION_DISCONNECTED {
			t.Fatalf("disconnect notification = %+v", closed)
		}
	})
}

func TestPresenceExpiryReservesDeviceUntilRendezvousCleanup(t *testing.T) {
	clock := newTestClock(time.Unix(100, 0))
	options := DefaultOptions()
	options.Now = clock.Now
	options.SweepInterval = time.Hour
	testServer := newServiceTestServer(t, options)
	host := testServer.dial(t)
	replacement := testServer.dial(t)
	hostBytes := testDeviceBytes(38)
	hostID, valid := state.DeviceIDFromBytes(hostBytes)
	if !valid {
		t.Fatal("invalid test device ID")
	}
	registerClient(t, host, hostBytes, "register-host")
	createRendezvous(t, host, testRendezvousBytes(38), roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR, "")
	if created := readServerFrame(t, host).GetRendezvousCreated(); created == nil {
		t.Fatal("old connection rendezvous creation response missing")
	}

	// Hold the expired connection open so the test controls the gap between
	// presence expiry and the old connection's cleanup.
	route, online := testServer.service.presence.Lookup(hostID)
	if !online || route.Close == nil {
		t.Fatal("registered host route missing")
	}
	closeExpiredConnection := route.Close
	route.Close = func() {}
	if !testServer.service.presence.Remove(hostID, route.Token) ||
		!testServer.service.presence.Register(hostID, route, clock.Now()) {
		t.Fatal("could not hold the expired route open")
	}

	clock.Advance(options.PresenceTimeout + time.Nanosecond)
	testServer.service.Sweep(clock.Now())
	writeRegister(t, replacement, hostBytes, "register-before-cleanup")
	if got := readServerFrame(t, replacement).GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_DEVICE_BUSY {
		t.Fatalf("registration before cleanup = %v, want device busy", got)
	}
	if got := testServer.service.RendezvousCount(); got != 1 {
		t.Fatalf("rendezvous before connection cleanup = %d, want 1", got)
	}

	closeExpiredConnection()
	waitFor(t, time.Second, func() bool { return testServer.service.PresenceCount() == 0 })
	if got := testServer.service.RendezvousCount(); got != 0 {
		t.Fatalf("rendezvous after connection cleanup = %d, want 0", got)
	}
	registerClient(t, replacement, hostBytes, "register-after-cleanup")
	createRendezvous(t, replacement, testRendezvousBytes(39), roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR, "")
	if created := readServerFrame(t, replacement).GetRendezvousCreated(); created == nil {
		t.Fatal("replacement connection rendezvous creation response missing")
	}
	if got := testServer.service.RendezvousCount(); got != 1 {
		t.Fatalf("replacement rendezvous = %d, want 1", got)
	}
}

func createAndJoinQR(t *testing.T, host *websocket.Conn, controller *websocket.Conn, rendezvousID []byte) {
	t.Helper()
	createRendezvous(t, host, rendezvousID, roammandv1.PairingRendezvousKind_PAIRING_RENDEZVOUS_KIND_QR, "")
	_ = readServerFrame(t, host)
	joinRendezvousByID(t, controller, rendezvousID, "join")
	_ = readServerFrame(t, controller)
	_ = readServerFrame(t, host)
}

func createRendezvous(
	t *testing.T,
	host *websocket.Conn,
	rendezvousID []byte,
	kind roammandv1.PairingRendezvousKind,
	pairingCode string,
) {
	t.Helper()
	writeClientFrame(t, host, &roammandv1.SignalingClientFrame{
		ProtocolVersion: protocolVersion(),
		RequestId:       "create-rendezvous",
		Payload: &roammandv1.SignalingClientFrame_CreateRendezvous{
			CreateRendezvous: &roammandv1.CreatePairingRendezvous{
				RendezvousId: rendezvousID,
				Kind:         kind,
				PairingCode:  pairingCode,
			},
		},
	})
}

func joinRendezvousByID(t *testing.T, client *websocket.Conn, rendezvousID []byte, requestID string) {
	t.Helper()
	writeClientFrame(t, client, &roammandv1.SignalingClientFrame{
		ProtocolVersion: protocolVersion(),
		RequestId:       requestID,
		Payload: &roammandv1.SignalingClientFrame_JoinRendezvous{
			JoinRendezvous: &roammandv1.JoinPairingRendezvous{
				Lookup: &roammandv1.JoinPairingRendezvous_RendezvousId{RendezvousId: rendezvousID},
			},
		},
	})
}

func joinRendezvousByCode(t *testing.T, client *websocket.Conn, pairingCode string, requestID string) {
	t.Helper()
	writeClientFrame(t, client, &roammandv1.SignalingClientFrame{
		ProtocolVersion: protocolVersion(),
		RequestId:       requestID,
		Payload: &roammandv1.SignalingClientFrame_JoinRendezvous{
			JoinRendezvous: &roammandv1.JoinPairingRendezvous{
				Lookup: &roammandv1.JoinPairingRendezvous_PairingCode{PairingCode: pairingCode},
			},
		},
	})
}

func relayPairing(t *testing.T, client *websocket.Conn, rendezvousID []byte, opaque []byte, requestID string) {
	t.Helper()
	writeClientFrame(t, client, &roammandv1.SignalingClientFrame{
		ProtocolVersion: protocolVersion(),
		RequestId:       requestID,
		Payload: &roammandv1.SignalingClientFrame_RelayPairing{
			RelayPairing: &roammandv1.RelayPairingEnvelope{
				RendezvousId:   rendezvousID,
				OpaqueEnvelope: opaque,
			},
		},
	})
}

func completeRendezvous(t *testing.T, client *websocket.Conn, rendezvousID []byte, requestID string) {
	t.Helper()
	writeClientFrame(t, client, &roammandv1.SignalingClientFrame{
		ProtocolVersion: protocolVersion(),
		RequestId:       requestID,
		Payload: &roammandv1.SignalingClientFrame_CompleteRendezvous{
			CompleteRendezvous: &roammandv1.CompletePairingRendezvous{
				RendezvousId: rendezvousID,
				Completion:   roammandv1.PairingRendezvousCompletion_PAIRING_RENDEZVOUS_COMPLETION_SUCCEEDED,
			},
		},
	})
}

func assertRoutedPairing(
	t *testing.T,
	frame *roammandv1.SignalingServerFrame,
	wantSender []byte,
	wantOpaque []byte,
) {
	t.Helper()
	routed := frame.GetRoutedPairing()
	if routed == nil ||
		!bytes.Equal(routed.GetSenderDeviceId(), wantSender) ||
		!bytes.Equal(routed.GetOpaqueEnvelope(), wantOpaque) {
		t.Fatalf("routed pairing = %+v", routed)
	}
}

func assertPairingRejected(t *testing.T, frame *roammandv1.SignalingServerFrame) {
	t.Helper()
	if got := frame.GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_PAIRING_REJECTED {
		t.Fatalf("pairing error = %v", got)
	}
}

func testRendezvousBytes(seed byte) []byte {
	encoded := make([]byte, 16)
	for index := range encoded {
		encoded[index] = seed
	}
	return encoded
}

// SPDX-License-Identifier: AGPL-3.0-only

package service

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	roammandv1 "github.com/MisakiHCL/roammand/gen/go/roammand/v1"
	validation "github.com/MisakiHCL/roammand/gen/go/validation"
	"github.com/coder/websocket"
)

func TestNegativeFramesReturnUniformPublicErrors(t *testing.T) {
	tests := []struct {
		name     string
		frame    *roammandv1.SignalingClientFrame
		wantCode roammandv1.ErrorCode
	}{
		{
			name: "unsupported protocol",
			frame: &roammandv1.SignalingClientFrame{
				ProtocolVersion: &roammandv1.ProtocolVersion{Major: 2},
				RequestId:       "unsupported",
				Payload: &roammandv1.SignalingClientFrame_Heartbeat{
					Heartbeat: &roammandv1.Heartbeat{},
				},
			},
			wantCode: roammandv1.ErrorCode_ERROR_CODE_PROTOCOL_UNSUPPORTED,
		},
		{
			name: "missing payload",
			frame: &roammandv1.SignalingClientFrame{
				ProtocolVersion: protocolVersion(),
				RequestId:       "missing-payload",
			},
			wantCode: roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST,
		},
		{
			name: "oversized request ID",
			frame: &roammandv1.SignalingClientFrame{
				ProtocolVersion: protocolVersion(),
				RequestId:       strings.Repeat("r", validation.MaxRequestIDUTF8Bytes+1),
				Payload: &roammandv1.SignalingClientFrame_Heartbeat{
					Heartbeat: &roammandv1.Heartbeat{},
				},
			},
			wantCode: roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST,
		},
		{
			name: "request ID near frame limit",
			frame: &roammandv1.SignalingClientFrame{
				ProtocolVersion: protocolVersion(),
				RequestId:       strings.Repeat("r", validation.MaxSignalingServiceFrameBytes-32),
				Payload: &roammandv1.SignalingClientFrame_Heartbeat{
					Heartbeat: &roammandv1.Heartbeat{},
				},
			},
			wantCode: roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			testServer := newServiceTestServer(t, DefaultOptions())
			client := testServer.dial(t)
			writeClientFrame(t, client, test.frame)
			response := readServerFrame(t, client)
			if got := response.GetError().GetCode(); got != test.wantCode {
				t.Fatalf("code = %v, want %v", got, test.wantCode)
			}
			if len(response.GetRequestId()) > validation.MaxRequestIDUTF8Bytes ||
				len(response.GetError().GetRequestId()) > validation.MaxRequestIDUTF8Bytes {
				t.Fatal("public error echoed an oversized request ID")
			}
			registerClient(t, client, testDeviceBytes(42), "register-after-invalid-frame")
		})
	}
}

func TestRegisteredClientRejectsInvalidPayloadLengthsAndEnums(t *testing.T) {
	testServer := newServiceTestServer(t, DefaultOptions())
	client := testServer.dial(t)
	registerClient(t, client, testDeviceBytes(40), "register")

	frames := []*roammandv1.SignalingClientFrame{
		{
			ProtocolVersion: protocolVersion(),
			RequestId:       "short-presence-id",
			Payload: &roammandv1.SignalingClientFrame_PresenceQuery{
				PresenceQuery: &roammandv1.PresenceQuery{DeviceId: []byte{1}},
			},
		},
		{
			ProtocolVersion: protocolVersion(),
			RequestId:       "invalid-rendezvous-kind",
			Payload: &roammandv1.SignalingClientFrame_CreateRendezvous{
				CreateRendezvous: &roammandv1.CreatePairingRendezvous{
					RendezvousId: testRendezvousBytes(9),
					Kind:         roammandv1.PairingRendezvousKind(99),
				},
			},
		},
		{
			ProtocolVersion: protocolVersion(),
			RequestId:       "empty-session-envelope",
			Payload: &roammandv1.SignalingClientFrame_RelaySession{
				RelaySession: &roammandv1.RelaySessionEnvelope{
					RecipientDeviceId: testDeviceBytes(41),
				},
			},
		},
	}
	for _, frame := range frames {
		writeClientFrame(t, client, frame)
		if got := readServerFrame(t, client).GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST {
			t.Fatalf("request %q code = %v", frame.GetRequestId(), got)
		}
	}
}

func TestTextAndOversizedFramesReturnErrorsBeforeClose(t *testing.T) {
	for name, send := range map[string]func(*testing.T, *websocket.Conn){
		"text": func(t *testing.T, client *websocket.Conn) {
			writeRawMessage(t, client, websocket.MessageText, []byte("not protobuf"))
		},
		"oversized": func(t *testing.T, client *websocket.Conn) {
			writeRawMessage(
				t,
				client,
				websocket.MessageBinary,
				make([]byte, validation.MaxSignalingServiceFrameBytes+1),
			)
		},
	} {
		t.Run(name, func(t *testing.T) {
			testServer := newServiceTestServer(t, DefaultOptions())
			client := testServer.dial(t)
			send(t, client)
			frame := readServerFrame(t, client)
			want := roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST
			if name == "oversized" {
				want = roammandv1.ErrorCode_ERROR_CODE_MESSAGE_TOO_LARGE
			}
			if got := frame.GetError().GetCode(); got != want {
				t.Fatalf("code = %v, want %v", got, want)
			}
		})
	}
}

func TestMalformedFrameDoesNotLeakInputOrInternalDetails(t *testing.T) {
	testServer := newServiceTestServer(t, DefaultOptions())
	client := testServer.dial(t)
	const secret = "private-key-material-must-not-leak"
	writeRawMessage(t, client, websocket.MessageBinary, append([]byte{0xff}, []byte(secret)...))
	frame := readServerFrame(t, client)
	if frame.GetError().GetCode() != roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST {
		t.Fatalf("code = %v", frame.GetError().GetCode())
	}
	if strings.Contains(frame.String(), secret) {
		t.Fatal("malformed input leaked into public error")
	}
}

func TestEveryM2PublicErrorCodeHasHandlerCoverage(t *testing.T) {
	covered := []roammandv1.ErrorCode{
		roammandv1.ErrorCode_ERROR_CODE_PAIRING_CODE_EXPIRED,
		roammandv1.ErrorCode_ERROR_CODE_PAIRING_RATE_LIMITED,
		roammandv1.ErrorCode_ERROR_CODE_PAIRING_REJECTED,
		roammandv1.ErrorCode_ERROR_CODE_DEVICE_OFFLINE,
		roammandv1.ErrorCode_ERROR_CODE_DEVICE_BUSY,
		roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST,
		roammandv1.ErrorCode_ERROR_CODE_PROTOCOL_UNSUPPORTED,
		roammandv1.ErrorCode_ERROR_CODE_MESSAGE_TOO_LARGE,
		internalError("coverage", context.DeadlineExceeded).GetError().GetCode(),
	}
	want := []roammandv1.ErrorCode{
		roammandv1.ErrorCode_ERROR_CODE_PAIRING_CODE_EXPIRED,
		roammandv1.ErrorCode_ERROR_CODE_PAIRING_RATE_LIMITED,
		roammandv1.ErrorCode_ERROR_CODE_PAIRING_REJECTED,
		roammandv1.ErrorCode_ERROR_CODE_DEVICE_OFFLINE,
		roammandv1.ErrorCode_ERROR_CODE_DEVICE_BUSY,
		roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST,
		roammandv1.ErrorCode_ERROR_CODE_PROTOCOL_UNSUPPORTED,
		roammandv1.ErrorCode_ERROR_CODE_MESSAGE_TOO_LARGE,
		roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE,
	}
	if !bytes.Equal(errorCodeBytes(covered), errorCodeBytes(want)) {
		t.Fatalf("covered = %v, want %v", covered, want)
	}
}

func writeRawMessage(t *testing.T, client *websocket.Conn, messageType websocket.MessageType, encoded []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := client.Write(ctx, messageType, encoded); err != nil {
		t.Fatal(err)
	}
}

func errorCodeBytes(codes []roammandv1.ErrorCode) []byte {
	encoded := make([]byte, len(codes))
	for index, code := range codes {
		encoded[index] = byte(code)
	}
	return encoded
}

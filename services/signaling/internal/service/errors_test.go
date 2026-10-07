// SPDX-License-Identifier: AGPL-3.0-only

package service

import (
	"errors"
	"strings"
	"testing"
	"time"

	roammandv1 "github.com/MisakiHCL/roammand/gen/go/roammand/v1"
	validation "github.com/MisakiHCL/roammand/gen/go/validation"
	"google.golang.org/protobuf/proto"
)

func TestPublicErrorMapping(t *testing.T) {
	tests := []struct {
		code       roammandv1.ErrorCode
		messageKey string
		retryable  bool
	}{
		{roammandv1.ErrorCode_ERROR_CODE_PAIRING_CODE_EXPIRED, "error.pairing_code_expired", false},
		{roammandv1.ErrorCode_ERROR_CODE_PAIRING_RATE_LIMITED, "error.pairing_rate_limited", true},
		{roammandv1.ErrorCode_ERROR_CODE_PAIRING_REJECTED, "error.pairing_rejected", false},
		{roammandv1.ErrorCode_ERROR_CODE_DEVICE_OFFLINE, "error.device_offline", true},
		{roammandv1.ErrorCode_ERROR_CODE_DEVICE_BUSY, "error.device_busy", true},
		{roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST, "error.invalid_request", false},
		{roammandv1.ErrorCode_ERROR_CODE_PROTOCOL_UNSUPPORTED, "error.protocol_unsupported", false},
		{roammandv1.ErrorCode_ERROR_CODE_MESSAGE_TOO_LARGE, "error.message_too_large", false},
		{roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE, "error.server_unavailable", true},
	}

	for _, test := range tests {
		t.Run(test.messageKey, func(t *testing.T) {
			frame := publicError(test.code, "request-1", 1500*time.Millisecond)
			protocolError := frame.GetError()
			if frame.GetRequestId() != "request-1" || protocolError.GetRequestId() != "request-1" {
				t.Fatalf("request IDs = (%q, %q)", frame.GetRequestId(), protocolError.GetRequestId())
			}
			if protocolError.GetCode() != test.code ||
				protocolError.GetMessageKey() != test.messageKey ||
				protocolError.GetRetryable() != test.retryable {
				t.Fatalf("unexpected error: %+v", protocolError)
			}
			if test.code == roammandv1.ErrorCode_ERROR_CODE_PAIRING_RATE_LIMITED {
				if got := protocolError.GetRetryAfter().GetRetryAfterMs(); got != 1500 {
					t.Fatalf("retry after = %d, want 1500", got)
				}
			} else if protocolError.GetDetails() != nil {
				t.Fatalf("unexpected details for %s", test.messageKey)
			}
		})
	}
}

func TestInternalErrorDoesNotLeakDetails(t *testing.T) {
	const secret = "database password appeared in stack"
	frame := internalError("request-2", errors.New(secret))
	protocolError := frame.GetError()

	if protocolError.GetCode() != roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE {
		t.Fatalf("code = %v", protocolError.GetCode())
	}
	if strings.Contains(protocolError.String(), secret) {
		t.Fatal("internal error leaked into public response")
	}
}

func TestUnknownPublicErrorFallsBackToServerUnavailable(t *testing.T) {
	frame := publicError(roammandv1.ErrorCode_ERROR_CODE_UNSPECIFIED, "request-3", 0)
	if got := frame.GetError().GetCode(); got != roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE {
		t.Fatalf("code = %v", got)
	}
}

func TestPublicErrorBoundsUnvalidatedRequestID(t *testing.T) {
	tests := []struct {
		name      string
		requestID string
		expected  string
	}{
		{"maximum bytes", strings.Repeat("a", validation.MaxRequestIDUTF8Bytes), strings.Repeat("a", validation.MaxRequestIDUTF8Bytes)},
		{"oversized", strings.Repeat("a", validation.MaxRequestIDUTF8Bytes+1), ""},
		{"maximum frame", strings.Repeat("a", validation.MaxSignalingServiceFrameBytes-32), ""},
		{"oversized UTF-8", strings.Repeat("界", validation.MaxRequestIDUTF8Bytes/3+1), ""},
		{"invalid UTF-8", string([]byte{0xff}), ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			frame := publicError(roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST, test.requestID, 0)
			if frame.GetRequestId() != test.expected || frame.GetError().GetRequestId() != test.expected {
				t.Fatalf("request ID lengths = (%d, %d), want %d", len(frame.GetRequestId()), len(frame.GetError().GetRequestId()), len(test.expected))
			}
			encoded, err := proto.Marshal(frame)
			if err != nil {
				t.Fatalf("public error does not marshal: %v", err)
			}
			if len(encoded) > validation.MaxSignalingServiceFrameBytes {
				t.Fatalf("public error length = %d, exceeds frame limit", len(encoded))
			}
		})
	}
}

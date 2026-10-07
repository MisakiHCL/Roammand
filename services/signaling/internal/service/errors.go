// SPDX-License-Identifier: AGPL-3.0-only

package service

import (
	"time"
	"unicode/utf8"

	roammandv1 "github.com/MisakiHCL/roammand/gen/go/roammand/v1"
	validation "github.com/MisakiHCL/roammand/gen/go/validation"
)

type errorSpec struct {
	messageKey string
	retryable  bool
}

var publicErrorSpecs = map[roammandv1.ErrorCode]errorSpec{
	roammandv1.ErrorCode_ERROR_CODE_PAIRING_CODE_EXPIRED: {
		messageKey: "error.pairing_code_expired",
	},
	roammandv1.ErrorCode_ERROR_CODE_PAIRING_RATE_LIMITED: {
		messageKey: "error.pairing_rate_limited",
		retryable:  true,
	},
	roammandv1.ErrorCode_ERROR_CODE_PAIRING_REJECTED: {
		messageKey: "error.pairing_rejected",
	},
	roammandv1.ErrorCode_ERROR_CODE_DEVICE_OFFLINE: {
		messageKey: "error.device_offline",
		retryable:  true,
	},
	roammandv1.ErrorCode_ERROR_CODE_DEVICE_BUSY: {
		messageKey: "error.device_busy",
		retryable:  true,
	},
	roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST: {
		messageKey: "error.invalid_request",
	},
	roammandv1.ErrorCode_ERROR_CODE_PROTOCOL_UNSUPPORTED: {
		messageKey: "error.protocol_unsupported",
	},
	roammandv1.ErrorCode_ERROR_CODE_MESSAGE_TOO_LARGE: {
		messageKey: "error.message_too_large",
	},
	roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE: {
		messageKey: "error.server_unavailable",
		retryable:  true,
	},
}

func publicError(
	code roammandv1.ErrorCode,
	requestID string,
	retryAfter time.Duration,
) *roammandv1.SignalingServerFrame {
	// Invalid frames can reach this path before their request ID is validated.
	// Do not copy an unbounded or malformed ID into both response fields.
	if len(requestID) > validation.MaxRequestIDUTF8Bytes || !utf8.ValidString(requestID) {
		requestID = ""
	}
	spec, exists := publicErrorSpecs[code]
	if !exists {
		code = roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE
		spec = publicErrorSpecs[code]
	}
	protocolError := &roammandv1.UnifiedError{
		Code:       code,
		MessageKey: spec.messageKey,
		Retryable:  spec.retryable,
		RequestId:  requestID,
	}
	if code == roammandv1.ErrorCode_ERROR_CODE_PAIRING_RATE_LIMITED && retryAfter > 0 {
		retryAfterMilliseconds := uint64((retryAfter + time.Millisecond - 1) / time.Millisecond)
		protocolError.Details = &roammandv1.UnifiedError_RetryAfter{
			RetryAfter: &roammandv1.RetryAfterDetails{
				RetryAfterMs: retryAfterMilliseconds,
			},
		}
	}
	frame := baseServerFrame(requestID)
	frame.Payload = &roammandv1.SignalingServerFrame_Error{Error: protocolError}
	return frame
}

func internalError(requestID string, _ error) *roammandv1.SignalingServerFrame {
	return publicError(
		roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE,
		requestID,
		0,
	)
}

func baseServerFrame(requestID string) *roammandv1.SignalingServerFrame {
	return &roammandv1.SignalingServerFrame{
		ProtocolVersion: &roammandv1.ProtocolVersion{Major: 1, Minor: 0},
		RequestId:       requestID,
	}
}

// SPDX-License-Identifier: AGPL-3.0-only

package service

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	roammandv1 "github.com/MisakiHCL/roammand/gen/go/roammand/v1"
	validation "github.com/MisakiHCL/roammand/gen/go/validation"
	"github.com/MisakiHCL/roammand/services/signaling/internal/config"
	"github.com/MisakiHCL/roammand/services/signaling/internal/safelog"
	"github.com/MisakiHCL/roammand/services/signaling/internal/state"
	"github.com/MisakiHCL/roammand/services/signaling/internal/transport"
	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"
)

const (
	WebSocketSubprotocol       = transport.WebSocketSubprotocol
	LegacyWebSocketSubprotocol = transport.LegacyWebSocketSubprotocol

	cacheControlHeader        = "Cache-Control"
	cacheControlNoStore       = "no-store"
	contentTypeOptionsHeader  = "X-Content-Type-Options"
	contentTypeOptionsNoSniff = "nosniff"
	inboundRateLimitReason    = "inbound rate limit exceeded"
)

type InboundLimits struct {
	Window              time.Duration
	FramesPerConnection int
	BytesPerConnection  int64
	FramesPerIP         int
	BytesPerIP          int64
	FramesGlobal        int
	BytesGlobal         int64
	IPWindowCapacity    int
}

type Options struct {
	Now                               func() time.Time
	RegistrationTimeout               time.Duration
	PresenceTimeout                   time.Duration
	SweepInterval                     time.Duration
	RendezvousTTL                     time.Duration
	RateLimitWindow                   time.Duration
	PairingAttemptsPerIP              int
	PairingAttemptsPerLookupKey       int
	OutboundQueueCapacity             int
	MaxFrameBytes                     int
	MessageReadTimeout                time.Duration
	MaxConnections                    int
	MaxConnectionsPerIP               int
	MaxRendezvous                     int
	MaxRendezvousPerHost              int
	MaxOutboundBytes                  int64
	MaxOutboundBytesPerIP             int64
	MaxOutboundBytesPerConnection     int64
	MaxInFlightReadBytes              int64
	MaxInFlightReadBytesPerIP         int64
	MaxInFlightReadBytesPerConnection int64
	TrustedProxyCIDRs                 []netip.Prefix
	InboundLimits                     InboundLimits
}

func DefaultOptions() Options {
	return Options{
		Now:                         time.Now,
		RegistrationTimeout:         config.RegistrationTimeout,
		PresenceTimeout:             config.PresenceTimeout,
		SweepInterval:               config.SweepInterval,
		RendezvousTTL:               config.RendezvousTTL,
		RateLimitWindow:             config.RateLimitWindow,
		PairingAttemptsPerIP:        config.PairingAttemptsPerIP,
		PairingAttemptsPerLookupKey: config.PairingAttemptsPerLookupKey,
		OutboundQueueCapacity:       config.OutboundQueueCapacity,
		MaxFrameBytes:               validation.MaxSignalingServiceFrameBytes,
		MessageReadTimeout:          config.MessageReadTimeout,
		MaxConnections:              config.DefaultMaxConnections,
		MaxConnectionsPerIP:         config.DefaultMaxConnectionsPerIP,
		MaxRendezvous:               config.DefaultMaxRendezvous,
		MaxRendezvousPerHost:        config.DefaultMaxRendezvousPerHost,
		MaxOutboundBytes:            config.DefaultGlobalOutboundByteBudget,
		MaxOutboundBytesPerIP:       config.DefaultPerIPOutboundByteBudget,
		MaxOutboundBytesPerConnection: int64(validation.MaxSignalingServiceFrameBytes) *
			config.OutboundFrameBudgetPerConnection,
		MaxInFlightReadBytes:      config.DefaultGlobalInFlightReadByteBudget,
		MaxInFlightReadBytesPerIP: config.DefaultPerIPInFlightReadByteBudget,
		MaxInFlightReadBytesPerConnection: int64(validation.MaxSignalingServiceFrameBytes) +
			config.InboundReadLimitProbeBytes,
		InboundLimits: InboundLimits{
			Window:              config.InboundRateLimitWindow,
			FramesPerConnection: config.InboundFramesPerConnection,
			BytesPerConnection:  config.InboundBytesPerConnection,
			FramesPerIP:         config.InboundFramesPerIP,
			BytesPerIP:          config.InboundBytesPerIP,
			FramesGlobal:        config.InboundFramesGlobal,
			BytesGlobal:         config.InboundBytesGlobal,
			IPWindowCapacity:    config.InboundIPWindowCapacity,
		},
	}
}

type Server struct {
	ctx                      context.Context
	cancel                   context.CancelFunc
	logger                   *safelog.Logger
	options                  Options
	mux                      *http.ServeMux
	presence                 *state.PresenceRegistry
	rendezvous               *state.RendezvousStore
	limiter                  *state.FixedWindowLimiter
	connectionSlots          chan struct{}
	globalOutboundBudget     *transport.ByteBudget
	globalInFlightReadBudget *transport.ByteBudget
	inboundLimiter           *state.TrafficLimiter
	nextToken                atomic.Uint64
	sourceIPMu               sync.Mutex
	sourceIPs                map[string]*sourceIPUsage
	lifecycleMu              sync.Mutex
	shuttingDown             bool
	shutdownWaitOnce         sync.Once
	shutdownDone             chan struct{}

	activeMu sync.Mutex
	active   map[*clientConnection]struct{}
	wait     sync.WaitGroup
}

type clientConnection struct {
	transport  *transport.Connection
	token      uint64
	remoteIP   string
	registered atomic.Bool
	deviceID   state.DeviceID
	inbound    inboundWindow
}

func New(ctx context.Context, logger *safelog.Logger, options Options) *Server {
	serverContext, cancel := context.WithCancel(ctx)
	if logger == nil {
		logger = safelog.Discard()
	}
	server := &Server{
		ctx:      serverContext,
		cancel:   cancel,
		logger:   logger,
		options:  options,
		mux:      http.NewServeMux(),
		presence: state.NewPresenceRegistry(),
		rendezvous: state.NewRendezvousStore(
			options.MaxRendezvousPerHost,
			options.MaxRendezvous,
		),
		limiter: state.NewFixedWindowLimiter(
			options.RateLimitWindow,
			options.PairingAttemptsPerIP,
			options.PairingAttemptsPerLookupKey,
			config.RateLimitIPWindowCapacity,
			config.RateLimitLookupCapacity,
		),
		connectionSlots:          make(chan struct{}, options.MaxConnections),
		globalOutboundBudget:     transport.NewByteBudget(options.MaxOutboundBytes),
		globalInFlightReadBudget: transport.NewByteBudget(options.MaxInFlightReadBytes),
		inboundLimiter: state.NewTrafficLimiter(
			options.InboundLimits.Window,
			options.InboundLimits.FramesGlobal,
			options.InboundLimits.BytesGlobal,
			options.InboundLimits.FramesPerIP,
			options.InboundLimits.BytesPerIP,
			options.InboundLimits.IPWindowCapacity,
		),
		sourceIPs:    make(map[string]*sourceIPUsage),
		active:       make(map[*clientConnection]struct{}),
		shutdownDone: make(chan struct{}),
	}
	server.mux.HandleFunc("/healthz", server.handleHealth)
	server.mux.HandleFunc("/v1/connect", server.handleConnect)
	server.wait.Add(1)
	go server.runSweeper()
	return server
}

func (server *Server) Handler() http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set(cacheControlHeader, cacheControlNoStore)
		writer.Header().Set(contentTypeOptionsHeader, contentTypeOptionsNoSniff)
		server.mux.ServeHTTP(writer, request)
	})
}

func (server *Server) PresenceCount() int {
	return server.presence.Len()
}

func (server *Server) RendezvousCount() int {
	return server.rendezvous.Len()
}

func (server *Server) ActiveConnectionCount() int {
	server.activeMu.Lock()
	defer server.activeMu.Unlock()
	return len(server.active)
}

func (server *Server) Sweep(now time.Time) {
	removedRendezvous := server.rendezvous.Sweep(now)
	for _, rendezvous := range removedRendezvous {
		server.notifyRendezvousClosed(
			rendezvous,
			roammandv1.PairingRendezvousCompletion_PAIRING_RENDEZVOUS_COMPLETION_EXPIRED,
			nil,
		)
	}
	expired := server.presence.ExpiredBefore(now.Add(-server.options.PresenceTimeout))
	for _, route := range expired {
		if route.Close != nil {
			route.Close()
		}
	}
	server.limiter.Sweep(now)
	server.inboundLimiter.Sweep(now)
}

func (server *Server) Shutdown(ctx context.Context) error {
	server.lifecycleMu.Lock()
	server.shuttingDown = true
	server.cancel()
	server.lifecycleMu.Unlock()

	server.activeMu.Lock()
	connections := make([]*clientConnection, 0, len(server.active))
	for connection := range server.active {
		connections = append(connections, connection)
	}
	server.activeMu.Unlock()
	for _, connection := range connections {
		connection.transport.CloseNow()
	}

	server.shutdownWaitOnce.Do(func() {
		go func() {
			server.wait.Wait()
			close(server.shutdownDone)
		}()
	})
	select {
	case <-server.shutdownDone:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (server *Server) handleHealth(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.Header().Set("Allow", http.MethodGet)
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	select {
	case <-server.ctx.Done():
		http.Error(
			writer,
			http.StatusText(http.StatusServiceUnavailable),
			http.StatusServiceUnavailable,
		)
		return
	default:
	}
	writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
	writer.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(writer, "ok\n")
}

func (server *Server) handleConnect(writer http.ResponseWriter, request *http.Request) {
	if !server.beginConnect() {
		http.Error(writer, http.StatusText(http.StatusServiceUnavailable), http.StatusServiceUnavailable)
		return
	}
	defer server.wait.Done()
	if !requestOffersSubprotocol(request, WebSocketSubprotocol) &&
		!requestOffersSubprotocol(request, LegacyWebSocketSubprotocol) {
		http.Error(writer, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	remoteAddress := remoteIP(
		request.RemoteAddr,
		request.Header.Values("X-Real-IP"),
		server.options.TrustedProxyCIDRs,
	)
	select {
	case server.connectionSlots <- struct{}{}:
	default:
		http.Error(
			writer,
			http.StatusText(http.StatusServiceUnavailable),
			http.StatusServiceUnavailable,
		)
		return
	}
	defer func() { <-server.connectionSlots }()
	ipBudgets, acquired := server.acquireIPConnection(remoteAddress)
	if !acquired {
		http.Error(
			writer,
			http.StatusText(http.StatusTooManyRequests),
			http.StatusTooManyRequests,
		)
		return
	}
	defer server.releaseIPConnection(remoteAddress)

	var connection *clientConnection
	var controlLimitCloseOnce sync.Once
	allowControlFrame := func(payload []byte) bool {
		if connection == nil {
			return false
		}
		if server.allowInbound(connection, len(payload), server.options.Now()) {
			return true
		}
		controlLimitCloseOnce.Do(func() {
			go connection.transport.Close(websocket.StatusTryAgainLater, inboundRateLimitReason)
		})
		return false
	}
	socket, err := websocket.Accept(writer, request, &websocket.AcceptOptions{
		Subprotocols: []string{
			WebSocketSubprotocol,
			LegacyWebSocketSubprotocol,
		},
		CompressionMode: websocket.CompressionDisabled,
		OnPingReceived: func(_ context.Context, payload []byte) bool {
			return allowControlFrame(payload)
		},
		OnPongReceived: func(_ context.Context, payload []byte) {
			_ = allowControlFrame(payload)
		},
	})
	if err != nil {
		return
	}
	if socket.Subprotocol() != WebSocketSubprotocol &&
		socket.Subprotocol() != LegacyWebSocketSubprotocol {
		_ = socket.Close(websocket.StatusPolicyViolation, "subprotocol required")
		return
	}

	connection = &clientConnection{
		transport: transport.NewConnection(
			socket,
			transport.ConnectionConfig{
				OutboundQueueCapacity: server.options.OutboundQueueCapacity,
				MaxFrameBytes:         server.options.MaxFrameBytes,
				MaxOutboundBytes:      server.options.MaxOutboundBytesPerConnection,
				SharedOutboundBudgets: []transport.ByteReservationBudget{
					ipBudgets.outbound,
					server.globalOutboundBudget,
				},
				MessageReadTimeout:   server.options.MessageReadTimeout,
				MaxInFlightReadBytes: server.options.MaxInFlightReadBytesPerConnection,
				SharedInFlightReadBudgets: []transport.ByteReservationBudget{
					ipBudgets.inFlightRead,
					server.globalInFlightReadBudget,
				},
			},
		),
		token:    server.nextToken.Add(1),
		remoteIP: remoteAddress,
	}
	server.activeMu.Lock()
	server.active[connection] = struct{}{}
	server.activeMu.Unlock()
	defer server.cleanupConnection(connection)

	connectionContext, cancel := context.WithCancel(server.ctx)
	defer cancel()
	writerDone := make(chan error, 1)
	go func() {
		writerDone <- connection.transport.RunWriter(connectionContext)
	}()
	registrationTimer := time.AfterFunc(server.options.RegistrationTimeout, func() {
		if !connection.registered.Load() {
			connection.transport.Close(websocket.StatusPolicyViolation, "registration required")
		}
	})
	defer registrationTimer.Stop()

	for {
		encoded, readErr := connection.transport.Read(connectionContext)
		if readErr != nil {
			if !errors.Is(readErr, context.Canceled) {
				server.handleReadError(connection, readErr)
			}
			break
		}
		if !server.allowInbound(connection, len(encoded), server.options.Now()) {
			connection.transport.Close(websocket.StatusTryAgainLater, inboundRateLimitReason)
			break
		}
		frame, code := decodeClientFrame(encoded)
		if code != roammandv1.ErrorCode_ERROR_CODE_UNSPECIFIED {
			server.sendFrame(connection, publicError(code, frame.GetRequestId(), 0))
			continue
		}
		if server.handleFrame(connection, frame) && connection.registered.Load() {
			registrationTimer.Stop()
		}
	}
	cancel()
	connection.transport.CloseNow()
	select {
	case <-writerDone:
	case <-time.After(time.Second):
	}
}

func (server *Server) beginConnect() bool {
	server.lifecycleMu.Lock()
	defer server.lifecycleMu.Unlock()
	if server.shuttingDown {
		return false
	}
	select {
	case <-server.ctx.Done():
		return false
	default:
	}
	server.wait.Add(1)
	return true
}

func (server *Server) handleReadError(connection *clientConnection, err error) {
	var code roammandv1.ErrorCode
	switch {
	case errors.Is(err, transport.ErrUnsupportedMessageType):
		code = roammandv1.ErrorCode_ERROR_CODE_INVALID_REQUEST
	case errors.Is(err, transport.ErrMessageTooLarge):
		code = roammandv1.ErrorCode_ERROR_CODE_MESSAGE_TOO_LARGE
	case errors.Is(err, transport.ErrMessageReadTimeout),
		errors.Is(err, transport.ErrInFlightReadBudgetExceeded):
		code = roammandv1.ErrorCode_ERROR_CODE_SERVER_UNAVAILABLE
	default:
		return
	}
	server.sendFrameAndWait(connection, publicError(code, "", 0))
}

func (server *Server) sendFrameAndWait(
	connection *clientConnection,
	frame *roammandv1.SignalingServerFrame,
) bool {
	encoded, err := proto.Marshal(frame)
	if err != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	return connection.transport.Send(ctx, encoded) == nil
}

func (server *Server) sendFrame(
	connection *clientConnection,
	frame *roammandv1.SignalingServerFrame,
) bool {
	encoded, err := proto.Marshal(frame)
	if err != nil {
		server.logger.Event(
			safelog.EventPublicFrameEncodeFailed,
			safelog.Fields{Code: safelog.CodeInternal},
		)
		connection.transport.CloseNow()
		return false
	}
	if connection.transport.TrySend(encoded) {
		return true
	}
	connection.transport.CloseNow()
	return false
}

func (server *Server) cleanupConnection(connection *clientConnection) {
	if connection.registered.Load() {
		removed := server.rendezvous.RemoveForDevice(connection.deviceID)
		// Keep the device ID reserved until its old rendezvous are gone. A new
		// connection must not create state that this cleanup could remove.
		server.presence.Remove(connection.deviceID, connection.token)
		for _, rendezvous := range removed {
			server.notifyRendezvousClosed(
				rendezvous,
				roammandv1.PairingRendezvousCompletion_PAIRING_RENDEZVOUS_COMPLETION_DISCONNECTED,
				&connection.deviceID,
			)
		}
	}
	server.activeMu.Lock()
	delete(server.active, connection)
	server.activeMu.Unlock()
	connection.transport.CloseNow()
}

func (server *Server) runSweeper() {
	defer server.wait.Done()
	ticker := time.NewTicker(server.options.SweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-server.ctx.Done():
			return
		case <-ticker.C:
			server.Sweep(server.options.Now())
		}
	}
}

func requestOffersSubprotocol(request *http.Request, required string) bool {
	for _, value := range request.Header.Values("Sec-WebSocket-Protocol") {
		for _, candidate := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(candidate), required) {
				return true
			}
		}
	}
	return false
}

func remoteIP(
	remoteAddress string,
	realIPHeaders []string,
	trustedProxies []netip.Prefix,
) string {
	directIP, ok := parseRemoteIP(remoteAddress)
	if !ok {
		return remoteAddress
	}
	trusted := false
	for _, prefix := range trustedProxies {
		if prefix.Contains(directIP) {
			trusted = true
			break
		}
	}
	if !trusted || len(realIPHeaders) != 1 || strings.Contains(realIPHeaders[0], ",") {
		return directIP.String()
	}
	forwardedIP, err := netip.ParseAddr(strings.TrimSpace(realIPHeaders[0]))
	if err != nil {
		return directIP.String()
	}
	return forwardedIP.Unmap().String()
}

func parseRemoteIP(remoteAddress string) (netip.Addr, bool) {
	host, _, err := net.SplitHostPort(remoteAddress)
	if err != nil {
		host = remoteAddress
	}
	parsed, err := netip.ParseAddr(host)
	if err != nil {
		return netip.Addr{}, false
	}
	return parsed.Unmap(), true
}

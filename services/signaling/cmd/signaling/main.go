// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/MisakiHCL/roammand/services/signaling/internal/buildinfo"
	"github.com/MisakiHCL/roammand/services/signaling/internal/config"
	"github.com/MisakiHCL/roammand/services/signaling/internal/safelog"
	"github.com/MisakiHCL/roammand/services/signaling/internal/service"
)

const (
	readHeaderTimeout = 5 * time.Second
	idleTimeout       = 60 * time.Second
	maxHeaderBytes    = 16 * 1024
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout, os.Stderr); err != nil {
		writeRunFailure(os.Stderr, err)
		os.Exit(1)
	}
}

func writeRunFailure(stderr io.Writer, _ error) {
	safelog.New(stderr).Event(
		safelog.EventServiceFailed,
		safelog.Fields{Code: safelog.CodeInternal},
	)
}

func run(
	ctx context.Context,
	getenv func(string) string,
	stdout io.Writer,
	stderr io.Writer,
) error {
	loaded, err := config.Load(getenv)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", loaded.ListenAddress)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer listener.Close()

	logger := safelog.New(stderr)
	options := service.DefaultOptions()
	options.TrustedProxyCIDRs = loaded.TrustedProxyCIDRs
	options.MaxConnections = loaded.MaxConnections
	options.MaxConnectionsPerIP = loaded.MaxConnectionsPerIP
	options.MaxRendezvous = loaded.MaxRendezvous
	options.MaxRendezvousPerHost = loaded.MaxRendezvousPerHost
	signalingServer := service.New(ctx, logger, options)
	httpServer := newHTTPServer(signalingServer.Handler(), logger)

	scheme := "ws"
	if loaded.TLSConfigured() {
		scheme = "wss"
	}
	serveResult := make(chan error, 1)
	go func() {
		if loaded.TLSConfigured() {
			serveResult <- httpServer.ServeTLS(
				listener,
				loaded.TLSCertificateFile,
				loaded.TLSPrivateKeyFile,
			)
			return
		}
		serveResult <- httpServer.Serve(listener)
	}()
	_, _ = fmt.Fprintf(
		stdout,
		"%s listening on %s://%s/v1/connect\n",
		buildinfo.ServiceName,
		scheme,
		listener.Addr().String(),
	)

	select {
	case serveErr := <-serveResult:
		shutdownErr := shutdown(signalingServer, httpServer, loaded.ShutdownTimeout)
		if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			return errors.Join(fmt.Errorf("serve: %w", serveErr), shutdownErr)
		}
		return shutdownErr
	case <-ctx.Done():
		shutdownErr := shutdown(signalingServer, httpServer, loaded.ShutdownTimeout)
		serveErr := <-serveResult
		if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			return errors.Join(shutdownErr, fmt.Errorf("serve: %w", serveErr))
		}
		return shutdownErr
	}
}

func newHTTPServer(handler http.Handler, logger *safelog.Logger) *http.Server {
	return &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: readHeaderTimeout,
		IdleTimeout:       idleTimeout,
		MaxHeaderBytes:    maxHeaderBytes,
		ErrorLog:          logger.HTTPErrorLog(),
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}
}

func shutdown(
	signalingServer *service.Server,
	httpServer *http.Server,
	timeout time.Duration,
) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	httpErr := httpServer.Shutdown(ctx)
	if httpErr != nil {
		_ = httpServer.Close()
	}
	signalingErr := signalingServer.Shutdown(ctx)
	return errors.Join(httpErr, signalingErr)
}

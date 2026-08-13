// Copyright (c) 2026 RongxinAI
//
// SPDX-License-Identifier: Apache-2.0

package client

import (
	"errors"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestCommonDialerBacksOffAndIncludesLastError(t *testing.T) {
	var attempts atomic.Int32
	dialErr := errors.New("vsock transport unavailable")
	start := time.Now()

	_, err := commonDialer(45*time.Millisecond, func() (net.Conn, error) {
		attempts.Add(1)
		return nil, dialErr
	}, errors.New("timed out connecting to test endpoint"))

	if err == nil {
		t.Fatal("expected dialer timeout")
	}
	if elapsed := time.Since(start); elapsed < 40*time.Millisecond {
		t.Fatalf("dialer returned too early: %s", elapsed)
	}
	if got := attempts.Load(); got > 5 {
		t.Fatalf("dialer retried %d times in 45ms; expected backoff", got)
	}
	if !strings.Contains(err.Error(), dialErr.Error()) {
		t.Fatalf("timeout error %q does not include the last dial error", err)
	}
}

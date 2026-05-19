// hs_client: hammer a TLS server with full handshakes and report rate.
//
// Usage:
//   client -addr host:port -conc N -duration 10s [-warmup 2s] [-curve x25519]
//
// One worker per -conc, each running a tight loop:
//   tls.Dial -> close -> repeat
// Session tickets are not stored (ClientSessionCache is nil) so every
// dial is a full handshake.

package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:4443", "server address")
	conc := flag.Int("conc", 16, "concurrent workers")
	dur := flag.Duration("duration", 10*time.Second, "measurement duration")
	warmup := flag.Duration("warmup", 2*time.Second, "warmup before measurement")
	curve := flag.String("curve", "x25519", "x25519 | p256")
	flag.Parse()

	var curveID tls.CurveID
	switch *curve {
	case "x25519":
		curveID = tls.X25519
	case "p256":
		curveID = tls.CurveP256
	default:
		fmt.Fprintf(os.Stderr, "unknown curve %q\n", *curve)
		os.Exit(2)
	}

	cfg := &tls.Config{
		InsecureSkipVerify: true, // bench server uses a throwaway cert
		MinVersion:         tls.VersionTLS13,
		MaxVersion:         tls.VersionTLS13,
		CurvePreferences:   []tls.CurveID{curveID},
		ClientSessionCache: nil, // ensure no resumption
	}

	if *warmup > 0 {
		runPhase(*addr, cfg, *conc, *warmup)
	}

	ok, fail, elapsed := runPhase(*addr, cfg, *conc, *dur)
	rate := float64(ok) / elapsed.Seconds()
	fmt.Printf("handshakes_ok=%d handshakes_failed=%d elapsed_s=%.3f rate_hs_per_s=%.2f\n",
		ok, fail, elapsed.Seconds(), rate)
}

func runPhase(addr string, cfg *tls.Config, conc int, dur time.Duration) (uint64, uint64, time.Duration) {
	var ok, fail uint64
	var wg sync.WaitGroup
	deadline := time.Now().Add(dur)
	start := time.Now()

	for i := 0; i < conc; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			dialer := &net.Dialer{Timeout: 5 * time.Second}
			for time.Now().Before(deadline) {
				rawConn, err := dialer.Dial("tcp", addr)
				if err != nil {
					atomic.AddUint64(&fail, 1)
					continue
				}
				// Linger 0: send RST on close, skipping TIME_WAIT and
				// avoiding ephemeral-port exhaustion when running at
				// thousands of handshakes/sec.
				if tcp, ok := rawConn.(*net.TCPConn); ok {
					_ = tcp.SetLinger(0)
				}
				conn := tls.Client(rawConn, cfg)
				if err := conn.Handshake(); err != nil {
					_ = rawConn.Close()
					atomic.AddUint64(&fail, 1)
					continue
				}
				_ = conn.Close()
				atomic.AddUint64(&ok, 1)
			}
		}()
	}

	wg.Wait()
	return ok, fail, time.Since(start)
}

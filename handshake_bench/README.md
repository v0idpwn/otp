# TLS handshake benchmark (OTP server / Go client)

Compare server-side TLS 1.3 full-handshake throughput between two OTP
installs. Designed for Linux (Graviton or otherwise); also works on macOS
with the same instructions.

## Getting the code

This benchmark lives on the `aws-lc-support` branch of the OTP fork at
`https://github.com/v0idpwn/otp`. On the test machine:

```sh
git clone --branch aws-lc-support --depth 1 https://github.com/v0idpwn/otp.git
cd otp/handshake_bench
```

The branch also contains the AWS-LC compatibility patches needed to build
one of the two OTP installs you'll be comparing.

## What it measures

- Pure TLS 1.3 full handshakes per second, server-side.
- Configurable certificate algorithm: **RSA-4096** or **ECDSA-P256**.
- Configurable ECDHE curve on the client: **x25519** (default) or **P-256**.
- Session tickets / resumption explicitly disabled — every connection is
  a full handshake (signature + key exchange + derive).
- No application data is exchanged. The server completes the handshake
  and immediately closes.

## Layout

```
handshake_bench/
  hs_server.erl    # Erlang TLS 1.3 server (accept -> handshake -> close)
  client.go        # Go client: N goroutines hammering tls.Dial
  gen_certs.sh     # Generates certs/rsa4096.{key,crt} and certs/ecdsa.{key,crt}
  README.md        # This file
```

## Prerequisites

- Two OTP installs you want to compare (e.g. one linked against OpenSSL,
  one against AWS-LC). Each provides its own `erl` and `erlc`.
- Go 1.20+ (`go build`)
- `openssl` (only for `gen_certs.sh`)

## Step 1 — Build the client and generate certs

```sh
cd handshake_bench
go build -o hs_client client.go
./gen_certs.sh
```

Re-run with `./gen_certs.sh --force` to regenerate.

## Step 2 — Tune the kernel for high handshake rates

At a few thousand handshakes/sec the client will burn through the local
ephemeral port range. The client already sets `SO_LINGER 0` so closed
connections send RST and skip TIME_WAIT, which is usually enough on its
own. If you still see `connect: cannot assign requested address`, also do:

```sh
# Widen the ephemeral range (defaults to ~28k ports)
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# Reuse TIME_WAIT sockets for outgoing connections (Linux only)
sudo sysctl -w net.ipv4.tcp_tw_reuse=1

# Raise the open-file limit if you set very high -conc
ulimit -n 65535
```

On macOS the linger-0 trick is usually enough and these sysctls have no
direct equivalent.

## Step 3 — Compile the server with each OTP

You need to compile `hs_server.erl` separately with each OTP's `erlc`
because BEAM files are tied to their toolchain.

```sh
mkdir -p build/otp_a build/otp_b
/path/to/otp_a/bin/erlc -o build/otp_a hs_server.erl
/path/to/otp_b/bin/erlc -o build/otp_b hs_server.erl
```

## Step 4 — Run the server

Pick which OTP and which cert. Each combination is a separate run. In one
terminal:

```sh
# RSA-4096 cert, OTP A
/path/to/otp_a/bin/erl -noshell -pa build/otp_a \
    -s hs_server start 4443 certs/rsa4096.crt certs/rsa4096.key
```

The server prints `READY <port>` once the listener is up.

## Step 5 — Run the client

In another terminal:

```sh
./hs_client -addr 127.0.0.1:4443 -conc 64 -duration 15s -curve x25519
```

Output:

```
handshakes_ok=12345 handshakes_failed=0 elapsed_s=15.001 rate_hs_per_s=823.27
```

Stop the server with Ctrl-C. Re-run with the next OTP / cert combination
and compare `rate_hs_per_s`.

### Knobs

- `-addr`: server address. Default `127.0.0.1:4443`.
- `-conc`: parallel TLS clients. Start with `2 * vCPUs`; scale up until
  CPU on the server saturates or rate plateaus.
- `-duration`: how long to measure. 15–30s gives stable numbers.
- `-warmup`: discarded warmup phase. Default 2s.
- `-curve`: `x25519` (TLS 1.3 default for most clients) or `p256`.

## Step 6 — The matrix

Run the full 2×2 (or 2×2×2 if you also vary the curve):

| OTP | Cert | Curve | hs/s |
|---|---|---|---|
| A (OpenSSL) | RSA-4096 | x25519 |   |
| A (OpenSSL) | ECDSA-P256 | x25519 |   |
| B (AWS-LC)  | RSA-4096 | x25519 |   |
| B (AWS-LC)  | ECDSA-P256 | x25519 |   |

The deltas to watch:
- **RSA-4096**: bottlenecked on RSA-sign. AWS-LC's ARMv8 Montgomery
  multiplication gives the biggest win here.
- **ECDSA-P256**: bottlenecked on ECDSA-sign + ECDHE. Less dramatic
  improvement but typically still positive on Graviton.
- **x25519 ECDHE**: AWS-LC's published number is +113% across Graviton
  2/3/Ice Lake vs prior implementations
  (https://www.amazon.science/blog/better-performing-25519-elliptic-curve-cryptography).

## Notes

- The server uses a tiny acceptor loop with a spawned worker per
  connection. Throughput is bounded by either crypto CPU on the server
  or client-side connection setup overhead — keep an eye on `top` /
  `htop` on both sides to see which.
- For best results, run server and client on **different physical
  machines** on a quiet network. Loopback works for relative comparison
  but inflates results because there's no NIC, no real RTT, and the
  client steals CPU from the server.
- The Go client is deliberately minimal. If you want pcap-able runs,
  swap in `openssl s_time` or a tool like `tlsfuzzer`'s
  `tlsperf` — the server side of this suite is unchanged.
- Cert key/cert reuse: BoringSSL/AWS-LC and OpenSSL handle PEM the same
  way; the same `certs/*.{crt,key}` files work with both OTPs.

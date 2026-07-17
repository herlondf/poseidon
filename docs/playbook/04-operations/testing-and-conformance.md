# Testing & Conformance

How Poseidon is validated: unit/logic tests, in-process fuzzing, a dual-face
compile gate, and protocol conformance suites.

## DUnitX suite (Windows)

The test project lives in `tests/`. Build and run:

```
tests\build_tests.bat
tests\Poseidon.Tests.exe
```

The suite covers the pure/logic surfaces (parser, HPACK, router, security,
validation, response builder, buffer pool, workers) and the built-in
middlewares, plus live-socket integration fixtures for the server.

> **Note:** the live-socket integration fixtures require a host whose Winsock
> supports the overlapped extension I/O (`AcceptEx` / RIO). Some sandboxed or
> Insider Windows builds reject those calls with `WSAEINVAL (10022)`, which makes
> those fixtures fail for an environmental reason — not a Poseidon defect. See
> [Platform notes](platform-notes.md). The pure/logic and fuzz fixtures always
> run headless.

## In-process fuzzing

`tests/Poseidon.Tests.Fuzz.pas` fuzzes the parsing surfaces that face untrusted
bytes — `ParseHTTP1Request`, `DecodeHTTP1Chunked`, `TH2HpackCodec.DecodeHeaders`
and `TWebSocketUtils.ParseFrame`. Each runs tens of thousands of deterministic,
seeded inputs (random + mutated) under a watchdog thread that flags an infinite
loop (a DoS). The invariant: **never crash, never hang, never leak an
exception** — the parser must always return, regardless of how malformed the
input is.

Fuzzing already caught a real remotely-triggerable DoS in the HPACK decoder
(invalid UTF-8 octets raised `EEncodingError`); see the security notes.

## Dual-face compile gate

A platform-specific bug behind `{$IFDEF MSWINDOWS}` / `{$ELSE}` (IOCP/RIO vs
epoll/io_uring) stays latent until deploy because each CI compiles only one face.
The gate compiles both:

```
pwsh ci\build-both-faces.ps1
```

- **Windows (Win64):** full build of the DUnitX project (`dcc64`).
- **Linux (Linux64):** compile check of the epoll / io_uring backends
  (`dcclinux64`). Without the Linux SDK the link step is skipped (only compile
  errors fail the gate); on a Linux runner with the SDK it links fully.

CI workflow: `.github/workflows/ci-both-faces.yml` (targets a self-hosted runner
labelled `delphi`, since the Delphi compiler is licensed and absent on
GitHub-hosted runners).

## HTTP/2 conformance (h2spec) on Linux

Because the live-socket path is exercised on **Linux** (where the Windows Winsock
limitation above does not apply), HTTP/2 conformance runs against a Linux build
in a throwaway WSL distro:

```
pwsh tests\run-h2spec.ps1              # create distro, build, run h2spec
pwsh tests\run-h2spec.ps1 -Cleanup     # tear the distro down afterwards
```

The script cross-compiles a headless h2-over-TLS server for Linux64, (re)creates
an Ubuntu WSL distro, provisions it (OpenSSL + h2spec), runs the suite and prints
the summary. It needs the Benchmark repo's Linux linker stubs (see the script
header for the expected path).

> **Current status:** **h2spec 145/146** over TLS/ALPN against the Linux io_uring
> backend (0 failed, 1 skip). The post-handshake TLS race that used to block this
> is resolved (see [Platform notes](platform-notes.md)).

## WebSocket conformance (Autobahn)

Runs the Autobahn TestSuite against a Linux build (`tests/autobahn/`). Current:
**247/247** core (suites 1–8, 10, 11) + **42/42** on the 9.\* large-payload
cases, 0 failures.

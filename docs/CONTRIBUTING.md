# Contributing to Poseidon

## Scope

Poseidon aims to be a zero-dependency Delphi async I/O library focused on:

- **Native syscalls only** — io_uring/epoll on Linux, IOCP on Windows; no third-party transport layer
- **Single WSASend per response** — eliminates Nagle stall from double-write patterns
- **Lock-free hot path** — buffer pool and context pool with TMonitor; no global lock on request dispatch
- **Protocol separation** — HttpServer handles I/O; adapters translate protocols; pools manage memory — never mix

## Technical guidelines

- `Poseidon.Net.HttpServer` selects and owns the IO backend (`TIOUringBackend` / `TEpollBackend` / `TIOCPBackend`). All other units are adapters — never add syscalls outside `Poseidon.Net.IO.*`.
- Never add `uses` of third-party libraries to any `Poseidon.Net.*` unit — zero external dependencies is a hard constraint.
- New units follow the naming convention `Poseidon.Net.<Module>.pas`.
- Platform compatibility: Linux 64-bit (io_uring ≥ 5.1 / epoll fallback) **and** Windows 64-bit (IOCP). Any `{$IFDEF}` block must cover both platforms. New IO backends go in `Poseidon.Net.IO.<Name>.pas` and implement `IIOBackend`.
- `class var` shared between threads → protect with `TMonitor` or `TCriticalSection`. See `Poseidon.Net.Pool.Buffer` as reference.
- `try/finally` mandatory whenever an object is allocated and must be freed.
- No empty `except` blocks. Log or re-raise.

## Suggested flow

1. Open an issue describing the bug, feature, or protocol addition.
2. Branch from `main`.
3. Add or adjust tests in `tests/` when the change affects observable behavior.
4. If adding a new sample, place it in `samples/NN-name/` with its own `.dpr` / `.dproj`.
5. Compile all affected samples to confirm no regression.
6. Update the playbook in `docs/playbook/` when the change affects usage, options, or observable behavior.
7. Open a pull request with an objective description of the problem and solution.

## Minimum validation

Always validate:

- Build of the test suite (`tests/`)
- Build of all samples (`samples/0N-*/`)
- Smoke test when the change touches the request dispatch path, buffer pool, or SSL handshake

## Adding a new protocol feature

1. If it requires new syscalls, create a `Poseidon.Net.IO.<Name>.pas` implementing `IIOBackend`, or extend an existing backend. Never add syscalls directly to `HttpServer.pas`.
2. Create a dedicated unit `Poseidon.Net.<Feature>.pas` for the protocol logic.
3. Expose it via a method on `TPoseidonNativeServer` — callers should not need to reference the new unit directly.
4. Add a sample in `samples/` and document it in `docs/playbook/03-protocols/`.

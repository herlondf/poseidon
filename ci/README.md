# CI harness (issue #204)

Two-face continuous integration for Poseidon: compile **and** test both the
Windows (IOCP/RIO) and Linux (epoll/io_uring) faces from a single entry point,
so a platform-specific bug can never sit latent behind an `{$IFDEF}` the other
platform never exercises.

## One command

```powershell
pwsh ci/run-ci.ps1                    # compile gate + fuzz + Win64 suite
pwsh ci/run-ci.ps1 -Linux             # + h2spec (TLS/ALPN h2) over WSL
pwsh ci/run-ci.ps1 -Linux -Autobahn   # + Autobahn WebSocket suite
```

Exit code `0` = all stages passed; non-zero otherwise.

## Stages

| Stage | What | Gate |
|-------|------|------|
| `compile-gate` | `dcc64` (Win64 test project) + `dcclinux64` (epoll/io_uring compile check) via `build-both-faces.ps1` | any COMPILE error fails |
| `fuzz` | socket-free `Poseidon.FuzzRunner.exe` — HTTP/1 + HPACK + WebSocket fuzz (60k iters each) and the deterministic invariant / smuggling guards | **100% green** (hard gate) |
| `win64-suite` | full DUnitX suite | any **new** failure fails; the 19 environmental Winsock failures (#203) are tolerated via `win64-known-failures.txt` |
| `h2spec` | HTTP/2 conformance over TLS/ALPN, reusing a provisioned WSL distro (CI-safe) | `>= total-1` passing (1 skip allowed) |
| `autobahn` | WebSocket conformance (Autobahn TestSuite) | zero failures |

## The Win64 baseline

On this project's Windows hosts the Winsock stack can reject `AcceptEx`/RIO
(`WSAEINVAL`, #203), so the socket-bound integration tests fail on Windows while
the Linux build serves fine. `win64-known-failures.txt` lists exactly those
tolerated failures; `run-ci.ps1` fails the build on any failure NOT in the list
and warns when a listed test starts passing (time to trim the baseline).

Regenerate the baseline only when the environment legitimately changes:

```powershell
[xml]$x = Get-Content tests/bin/DUnitX-Results.xml
$x.SelectNodes('//test-case') | ? { $_.success -ne 'True' } |
  % { $_.name } | Sort-Object -Unique
```

## Linux conformance — one-time WSL provisioning

The Linux stages reuse **already-provisioned** WSL distros (they never recreate a
distro or run `wsl --shutdown`, so other distros on the machine are untouched):

- **`PoseidonH2Spec`** — provision once (creates the distro, installs OpenSSL +
  h2spec):
  ```powershell
  pwsh tests/run-h2spec.ps1            # first run: creates + provisions + runs
  pwsh tests/run-h2spec.ps1 -Reuse     # thereafter: rebuild ELF + re-run only
  ```
- **`Benchmark`** — a WSL distro with Docker, used to run the
  `crossbario/autobahn-testsuite` container. See `tests/autobahn/`.

## GitHub Actions

`.github/workflows/ci.yml` runs `run-ci.ps1` on a **self-hosted** Windows runner
(label `delphi`) — GitHub-hosted runners cannot build Poseidon (no RAD Studio).
The core `compile-and-test` job runs on every push/PR; the `linux-conformance`
job is opt-in via `workflow_dispatch` so a busy dev machine is not disrupted.

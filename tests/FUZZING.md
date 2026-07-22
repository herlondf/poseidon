# Poseidon FuzzRunner

`Poseidon.FuzzRunner` is a dedicated, **socket-free** executable that fuzzes the
Poseidon parsing surfaces — the code that faces **untrusted bytes** straight off
the wire. Fuzzing throws tens of thousands of random, mutated and adversarial
inputs at each parser and asserts a single invariant:

> **Never crash, never hang, never leak an exception** — the parser must always
> return, no matter how malformed the input is.

A normal test checks the *happy path*. Fuzzing checks the **hostile** path — the
one an attacker actually controls on a public HTTP server.

---

## Why it is a separate program

The runner attacks only the **pure parsing surfaces** — no sockets, no live
server, no Winsock/epoll dependency:

| Surface | Entry point | Issue |
|---------|-------------|-------|
| HTTP/1 request / chunked | `ParseHTTP1Request`, `DecodeHTTP1Chunked` | #200 (smuggling) |
| HPACK header decoder (HTTP/2) | `TH2HpackCodec.DecodeHeaders` | #201 |
| WebSocket framing | `TWebSocketUtils.ParseFrame` | #199 |
| WebSocket UTF-8 (RFC 3629) | `IsValidUTF8` | #217 |

Because it needs no network environment, it is **fast and self-contained** — it
can run continuously (per-push CI gate, nightly, local endurance) without the
live-socket host the full DUnitX suite requires. That is why it lives in its own
`.dpr` instead of inside the main suite.

The fuzz fixtures live in `tests/Poseidon.Tests.Fuzz.pas`; the runner that hosts
them is `tests/Poseidon.FuzzRunner.dpr`.

---

## How it works

1. **Deterministic PRNG (`xorshift64`).** Each fixture is seeded with a fixed
   base seed, so every run is **reproducible** — find a crash and the same seed
   replays the exact byte sequence that triggered it.
2. **Random + mutated inputs.** Each surface runs tens of thousands of
   iterations: some buffers are pure random bytes, others start from a *valid*
   frame / UTF-8 string and corrupt a few bytes — keeping the fuzzer near the
   continuation / overlong / surrogate decision boundaries where bugs hide.
3. **Invariant check.** Each buffer is fed to the parser; the test asserts it
   never raises and never hangs.
4. **Stall-based watchdog.** A separate thread fails the run only if the
   iteration counter **stops advancing** — i.e. a single input drove the parser
   into an infinite loop (a real DoS). Being per-stall rather than per-run, it
   never false-trips however far `FUZZ_SCALE` stretches the iteration count.
5. **Regression guards.** Known crash vectors become deterministic assertions
   (e.g. `THPACKInvariantTests`, `TFuzzWebSocketUtf8Tests.KnownVectors_…`), so a
   fixed bug can never silently return.

Fuzzing has already caught a **real, remotely-triggerable DoS** in the HPACK
decoder (invalid UTF-8 octets raised `EEncodingError`). That is the whole point.

---

## Tuning knobs (environment variables)

Both default to today's exact behaviour, so the per-push gate stays fast and
deterministic. The nightly job overrides them to explore a much wider space.

| Variable | Meaning | Default |
|----------|---------|---------|
| `FUZZ_SCALE` | Integer ≥ 1 (capped at 1000). Multiplies the iteration count. | `1` |
| `FUZZ_SEED`  | Hex (`0x…`) or decimal salt, XORed into every base seed — shifts the whole run to a fresh input space. | unset → `0` (deterministic regression corpus) |

---

## Build and run

```bat
tests\build_fuzz.bat          :: dcc64 -> tests\Poseidon.FuzzRunner.exe
tests\Poseidon.FuzzRunner.exe :: 24 fixtures, exit 0 = all passed
```

Run a longer, freshly-salted campaign locally:

```pwsh
$env:FUZZ_SCALE = '20'
$env:FUZZ_SEED  = '0xC0FFEE'
tests\Poseidon.FuzzRunner.exe
```

A non-zero exit code means a crash, a failed assertion, or a watchdog stall.

---

## Where it runs in CI

- **Every push / PR** — `.github/workflows/ci.yml` runs `ci/run-ci.ps1`, which
  builds both platform faces and runs the FuzzRunner over the **deterministic
  regression corpus** as a **hard gate**. Any crash blocks the merge. Fast.
- **Nightly** — `.github/workflows/fuzz-nightly.yml` (04:00 UTC) re-runs the
  same runner with a large `FUZZ_SCALE` and a **fresh per-run `FUZZ_SEED`**,
  covering far more input space than a single push can afford. It records the
  exact seed it used as a build artifact (`fuzz-seed.txt`).

### Reproducing a nightly failure

The failing run records its `FUZZ_SEED` in the `fuzz-nightly-<run_id>` artifact.
Replay it locally for a deterministic repro, then add the seed to a regression
guard once the bug is fixed:

```bat
set FUZZ_SEED=<seed-from-artifact>
set FUZZ_SCALE=1
tests\Poseidon.FuzzRunner.exe
```

---

## Fixtures

| Fixture | Covers |
|---------|--------|
| `TFuzzHTTP1ParserTests` | Random + mutated HTTP/1 requests and chunked bodies |
| `TFuzzHPACKTests` | Random + structured HPACK header blocks |
| `TFuzzWebSocketTests` | Random + mutated WebSocket frames |
| `TFuzzWebSocketUtf8Tests` | WebSocket text/close UTF-8 validation (RFC 3629) + known vectors |
| `THTTP1SmugglingTests` | Deterministic RFC 7230 §3.3.3 desync guards |
| `THPACKInvariantTests` | Deterministic HPACK regression guards |

See also the playbook: [Testing & Conformance](../docs/playbook/04-operations/testing-and-conformance.md).

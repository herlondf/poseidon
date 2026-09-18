# Reproducing "Performance vs. the Field"

The comparison table in the main [README](../README.md) ("Performance vs. o
Mercado" / "Performance vs. the Field") is not a claim you have to take on
faith. This folder builds and measures all 8 contenders from source, one at a
time, entirely inside Docker. If you doubt the numbers, this is how you check
them yourself.

## Requirements

**Only Docker** (Engine + Compose plugin) on the host. Nothing else - no
Rust, Go, .NET, Delphi, or FPC toolchain needs to be installed on the host
itself; every contender (including the three Object Pascal ones, and the
`wrk` load generator) builds and runs entirely inside containers.

Tested on Linux (native Docker Engine) and Windows (Docker Desktop). WSL2 is
not required on Windows - the script only talks to the Docker daemon.

Expect the first run to take a while: the shared FPC trunk base image (needed
because Poseidon, mORMot2 and Horse's epoll provider all use Delphi
`reference to` types, which only FPC 3.3.1/trunk supports - see
`docker/fpc-trunk/Dockerfile`) compiles a whole compiler from source. That
layer is cached by Docker after the first build, so every run after the first
is fast to build.

## Run it

```bash
cd benchmark
./scripts/run-all.sh                 # all 8 contenders, 300s measurement each
./scripts/run-all.sh poseidon-v2 uws  # just these two
DURATION=30 ./scripts/run-all.sh      # short smoke-test run
```

On Windows (PowerShell, Docker Desktop):

```powershell
cd benchmark
.\scripts\run-all.ps1
```

Each contender is built, started, warmed up, measured, and torn down before
the next one begins - never two contenders running at once, so none of them
steals CPU/memory from another's measurement window. Every contender gets
identical `--cpus`/`--memory` caps and the same weighted request mix (40%
`/plaintext`, 30% `/json`, 30% `/json-large` ~62KB), via
[`loadgen/bench.lua`](loadgen/bench.lua) - the same script and proportions as
the run that produced the numbers currently in the main README (2026-08-30).

Raw `wrk` output lands in `results/raw/<framework>.log`; the final ranked
table is written to `results/RESULTS.md` (same format as the README table -
copy it over directly).

## What's in here

| Contender | Language | Build |
|---|---|---|
| `frameworks/uws` | C++ | Clones uWebSockets+uSockets, builds with g++ - fully self-contained |
| `frameworks/actix` | Rust | Cargo multi-stage build - fully self-contained |
| `frameworks/poseidon-v2` | Object Pascal | FPC trunk against `../../src` (this repo's own source, always live, never a copy) |
| `frameworks/gofiber` | Go | Go multi-stage build - fully self-contained |
| `frameworks/mormot2` | Object Pascal | FPC trunk, clones the public `synopse/mORMot2` upstream fresh |
| `frameworks/nginx` | C | Official nginx image + static config - the "hardware ceiling" reference, not an app framework |
| `frameworks/horse-epoll` | Object Pascal | FPC trunk, clones the public `HashLoad/horse` upstream fresh (latest commit - the epoll provider may not be in a tagged release yet) |
| `frameworks/kestrel` | C#/.NET | dotnet SDK multi-stage build - fully self-contained |

`docker/fpc-trunk/` is the shared FPC 3.3.1 (trunk) base image the three
Pascal contenders build on top of.

`loadgen/` is the `wrk` (with Lua scripting) container - the load generator
runs in its own container too, on the same dedicated bridge network as the
target, so the benchmark truly needs nothing beyond Docker on the host.

## Methodology notes / honest caveats

- **Bridge network, not host network.** The original one-off run that
  produced the published table used `--network host` (Linux-only, not
  portable to Windows+Docker Desktop). This script uses a dedicated bridge
  network instead, so the same script works on both platforms. Bridge
  networking adds a small NAT hop the original run didn't have - absolute
  numbers here may run a little lower across the board than the published
  table for that reason. The *relative ranking* between contenders is what
  this script is for; treat small differences in absolute throughput between
  a bridge-network run and the original host-network numbers as methodology,
  not regression.
- **Horse's epoll provider is a recent addition** to the public repo and may
  not be in a tagged release - the build clones the default branch's latest
  commit, not a pinned version. A build failure here reflects upstream
  Horse's current state, not this script.
- **mORMot2 builds without its optional static libraries** (the ones
  distributed separately from `synopse.info`, not part of the public git
  repo) - smart-linking (`-CX -XX -Xs`) works around the units that would
  need them. This matches the build that produced the published numbers, not
  a change made for this script.
- All three Pascal contenders compile with the **same** FPC trunk toolchain
  and the **same** optimization flags (`-O2`, Delphi-compatible mode) - the
  point of the shared base image is exactly to keep that tier apples-to-apples.

## Extending it

To add a contender: create `frameworks/<name>/Dockerfile` (serving
`/plaintext`, `/json`, `/json-large` on port 8080, matching every other
contender's contract) and add its name/display-name/technology to
`scripts/parse-results.sh`'s `display_name`/`display_tech` functions.

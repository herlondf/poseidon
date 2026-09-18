#!/bin/bash
# Poseidon "Performance vs. the Field" benchmark - full reproduction.
#
# Builds and measures each contender ONE AT A TIME (never simultaneously, so
# no framework's run is affected by another's CPU/memory footprint), on a
# dedicated Docker bridge network, with identical CPU/memory caps for every
# contender. The ONLY host requirement is Docker (Engine + Compose plugin) -
# the load generator (wrk) is itself a container, not a host tool.
#
# Usage:
#   ./run-all.sh                      # all frameworks, 300s each (default)
#   ./run-all.sh poseidon-v2 uws      # only these two
#   DURATION=60 ./run-all.sh          # shorter runs (smoke-test the script)
#
# Output: benchmark/results/raw/<framework>.log (full wrk output) and
# benchmark/results/RESULTS.md (the generated comparison table).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # benchmark/
REPO="$(cd "$ROOT/.." && pwd)"          # Poseidon repo root (Docker build context)
RESULTS="$ROOT/results"
RAW="$RESULTS/raw"
NET=bench-net
CPUS="${CPUS:-2.0}"
MEMORY="${MEMORY:-1g}"
DURATION="${DURATION:-300}"
THREADS="${THREADS:-4}"
CONNS="${CONNS:-200}"
WARMUP_S="${WARMUP_S:-5}"
COOLDOWN_S="${COOLDOWN_S:-5}"

ALL_FRAMEWORKS=(uws actix poseidon-v2 gofiber mormot2 nginx horse-epoll kestrel)
FRAMEWORKS=("$@")
[ ${#FRAMEWORKS[@]} -eq 0 ] && FRAMEWORKS=("${ALL_FRAMEWORKS[@]}")

mkdir -p "$RAW"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---- one-time setup ---------------------------------------------------------

log "Building shared FPC trunk base image (slow the first time, cached after)..."
docker build -t poseidon-bench/fpc-trunk -f "$ROOT/docker/fpc-trunk/Dockerfile" "$ROOT/docker/fpc-trunk/" \
  || { echo "FPC trunk base image build FAILED"; exit 1; }

log "Building load generator image (wrk)..."
docker build -t poseidon-bench/loadgen "$ROOT/loadgen/" \
  || { echo "loadgen image build FAILED"; exit 1; }

if ! docker network inspect "$NET" >/dev/null 2>&1; then
  log "Creating dedicated bridge network $NET"
  docker network create "$NET" >/dev/null
fi

# ---- per-framework build ----------------------------------------------------

build_one() {
  local name="$1"
  local dir="$ROOT/frameworks/$name"
  if [ ! -f "$dir/Dockerfile" ]; then
    log "  SKIP $name: no Dockerfile at $dir"
    return 1
  fi
  # The 3 Pascal contenders build from Poseidon's own src/ (repo root as
  # context); the other 5 are fully self-contained in their own directory
  # (original upstream design, unchanged) - each needs its OWN dir as context.
  local context="$dir"
  case "$name" in
    poseidon-v2|mormot2|horse-epoll) context="$REPO" ;;
  esac
  log "Building bench-$name (context: $context) ..."
  docker build -t "bench-$name" -f "$dir/Dockerfile" "$context" > "$RAW/$name.build.log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    log "  BUILD FAILED for $name - see $RAW/$name.build.log"
    tail -30 "$RAW/$name.build.log"
    return 1
  fi
  log "  built bench-$name"
  return 0
}

# ---- run one framework: start, wait, measure, teardown ----------------------

run_one() {
  local name="$1"
  local container="bench-target"

  docker rm -f "$container" >/dev/null 2>&1

  log "[$name] starting container (--cpus=$CPUS --memory=$MEMORY)"
  # seccomp=unconfined: Docker's default seccomp profile blocks the
  # io_uring_setup/io_uring_enter syscalls, silently forcing Poseidon down to
  # its epoll fallback - confirmed live (backend=epoll under the default
  # profile, backend=io_uring with this flag, same image). Applied to every
  # contender uniformly, not just Poseidon, so no one gets an asymmetric
  # syscall restriction.
  docker run -d --name "$container" --network "$NET" \
    --cpus="$CPUS" --memory="$MEMORY" --security-opt seccomp=unconfined \
    "bench-$name" >/dev/null \
    || { log "[$name] docker run FAILED"; return 1; }

  log "[$name] waiting for readiness..."
  local ready=0
  for i in $(seq 1 30); do
    if docker run --rm --network "$NET" --entrypoint curl poseidon-bench/loadgen \
         -sf -o /dev/null "http://$container:8080/plaintext" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" != 1 ]; then
    log "[$name] NEVER BECAME READY - skipping, dumping container log"
    docker logs "$container" 2>&1 | tail -40
    docker rm -f "$container" >/dev/null 2>&1
    return 1
  fi

  log "[$name] warmup ${WARMUP_S}s..."
  docker run --rm --network "$NET" poseidon-bench/loadgen \
    -t"$THREADS" -c"$CONNS" -d"${WARMUP_S}s" -s /bench.lua "http://$container:8080" >/dev/null 2>&1

  log "[$name] measuring for ${DURATION}s (t=$THREADS c=$CONNS)..."
  docker run --rm --network "$NET" poseidon-bench/loadgen \
    -t"$THREADS" -c"$CONNS" -d"${DURATION}s" --latency -s /bench.lua "http://$container:8080" \
    > "$RAW/$name.log" 2>&1

  log "[$name] tearing down"
  docker rm -f "$container" >/dev/null 2>&1

  log "[$name] cooldown ${COOLDOWN_S}s"
  sleep "$COOLDOWN_S"
}

# ---- main loop ---------------------------------------------------------------

for fw in "${FRAMEWORKS[@]}"; do
  echo
  echo "=================================================================="
  echo " $fw"
  echo "=================================================================="
  build_one "$fw" || continue
  run_one "$fw"
done

log "Parsing results..."
bash "$HERE/parse-results.sh" "${FRAMEWORKS[@]}" | tee "$RESULTS/RESULTS.md"
log "Done. Table written to $RESULTS/RESULTS.md"

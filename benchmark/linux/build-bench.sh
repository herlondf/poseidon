#!/usr/bin/env bash
# benchmark/linux/build-bench.sh
# Compila BenchServer para Linux64 usando dcclinux64 (cross-compiler Delphi).
#
# Pré-requisitos:
#   - dcclinux64 no PATH (parte do Delphi 11/Alexandria ou via Wine+RAD Server)
#   - sysroot Linux configurado em $SYSROOT
#
# Uso:
#   ./benchmark/linux/build-bench.sh
#   BDS=/opt/emb/studio/22.0 SYSROOT=/usr/lib/x86_64-linux-gnu ./build-bench.sh

set -euo pipefail

BDS="${BDS:-/opt/Embarcadero/Studio/22.0}"
SYSROOT="${SYSROOT:-/usr/lib/x86_64-linux-gnu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/../.."
BENCH_SRC="${ROOT}/benchmark/src"
ASSETS="${SCRIPT_DIR}/assets"

mkdir -p "${ASSETS}"

compile() {
  local DEFINES="$1"
  local OUT_NAME="$2"

  echo "==> Compilando: ${OUT_NAME} (defines: ${DEFINES})"

  dcclinux64 \
    -U"${ROOT}/src:${BENCH_SRC}:${BDS}/lib/Linux64/release" \
    -I"${ROOT}/src:${BENCH_SRC}" \
    -D"${DEFINES}" \
    -E"${ASSETS}" \
    -N0"${SCRIPT_DIR}/dcu" \
    --no-config \
    -CC \
    "${BENCH_SRC}/BenchServer.dpr"

  if [ -f "${ASSETS}/BenchServer" ]; then
    mv "${ASSETS}/BenchServer" "${ASSETS}/${OUT_NAME}"
    chmod +x "${ASSETS}/${OUT_NAME}"
    echo "    → ${ASSETS}/${OUT_NAME}"
  else
    echo "ERROR: BenchServer not produced" >&2
    exit 1
  fi
}

mkdir -p "${SCRIPT_DIR}/dcu"

compile "POSEIDON;NOGUI;RELEASE"           "bench-poseidon.linux64"
compile "HORSE_CROSSSOCKET;NOGUI;RELEASE"  "bench-horse-cs.linux64"

echo ""
echo "Build concluído:"
ls -lh "${ASSETS}"/*.linux64

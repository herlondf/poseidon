# Poseidon v2 contender - built from source inside Docker (no pre-built ELF,
# no licensed Delphi needed). Build context MUST be the repo root (Poseidon/),
# so this Dockerfile can reach ../../src and ../../middlewares directly -
# always the live source, never a copy that can drift.
#
#   docker build -f benchmark/frameworks/poseidon-v2/Dockerfile -t bench-poseidon-v2 .
#
# Two-stage: compile with FPC trunk (see benchmark/docker/fpc-trunk), then
# copy just the ELF + payload into a minimal runtime image.

FROM poseidon-bench/fpc-trunk AS build

WORKDIR /build
COPY src/ ./src/
COPY benchmark/frameworks/poseidon-v2/bench-poseidon.dpr ./bench-poseidon.dpr
RUN mkdir -p ./out

# Same flags as tests/fpc/build-linux-fpc.sh: -MDELPHIUNICODE (Delphi-mode
# UnicodeString default) + -Mfunctionreferences/-Manonymousfunctions (Delphi
# `reference to` types, trunk-only) + -Mprefixedattributes.
RUN FPCVER="$(cat /opt/fpc-trunk/VERSION)" \
 && /opt/fpc-trunk/lib/fpc/"$FPCVER"/ppcx64 -Tlinux \
      -MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes \
      -Fu/opt/fpc-trunk/lib/fpc/"$FPCVER"/units/x86_64-linux/rtl \
      -Fu"/opt/fpc-trunk/lib/fpc/$FPCVER/units/x86_64-linux/*" \
      -Fu./src -Fu./src/compat -FU./out -FE./out -O3 -vw \
      -o./out/bench_poseidon \
      ./bench-poseidon.dpr \
 && test -x ./out/bench_poseidon

FROM debian:12-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libssl3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/out/bench_poseidon /app/server
COPY benchmark/assets/large.json /app/large.json
EXPOSE 8080
CMD ["./server"]

# mORMot2 contender - built from source inside Docker. Clones the public
# upstream (github.com/synopse/mORMot2) fresh at build time - no vendored
# copy, no static libs (mormot.crypt.core's ASMX64 path {$L}-inks
# static/x86_64-linux/*.o object files distributed separately, outside the
# public git repo, from synopse.info - not fetched here). -dNOASMBLOCK
# (mormot.defines.inc's own documented pure-Pascal escape hatch) disables
# that whole asm path, avoiding the missing .o files entirely - a real
# perf cost for mORMot2 specifically (loses hand-tuned x86-64 asm for
# crypto/hashing), not something this benchmark's minimal HTTP handler
# exercises at all, but worth being explicit about for anyone comparing
# raw numbers against a full-static mORMot2 build elsewhere.
#
# NOTE: no -MDELPHIUNICODE/-Mfunctionreferences/-Manonymousfunctions here,
# unlike poseidon-v2/horse-epoll - mORMot2 manages its own compiler mode via
# {$I mormot.defines.inc}; forcing DELPHIUNICODE from the command line
# breaks mormot.core.unicode.pas (ancestor-method-signature errors) - own
# testing confirmed removing these flags fixes it.
#
#   docker build -f benchmark/frameworks/mormot2/Dockerfile -t bench-mormot2 .

FROM poseidon-bench/fpc-trunk AS build

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 https://github.com/synopse/mORMot2.git mormot2
COPY benchmark/frameworks/mormot2/bench-mormot.dpr ./bench-mormot.dpr
RUN mkdir -p ./out

RUN FPCVER="$(cat /opt/fpc-trunk/VERSION)" \
 && /opt/fpc-trunk/lib/fpc/"$FPCVER"/ppcx64 -Tlinux -O2 -CX -XX -Xs -vw \
      -dNOASMBLOCK \
      -Fu/opt/fpc-trunk/lib/fpc/"$FPCVER"/units/x86_64-linux/rtl \
      -Fu"/opt/fpc-trunk/lib/fpc/$FPCVER/units/x86_64-linux/*" \
      -Fumormot2/src/core -Fumormot2/src/net -Fumormot2/src/lib \
      -Fumormot2/src/crypt -Fumormot2/src/db -Fimormot2/src \
      -FU./out -FE./out \
      -o./out/bench_mormot \
      ./bench-mormot.dpr \
 && test -x ./out/bench_mormot

FROM debian:12-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libssl3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/out/bench_mormot /app/server
COPY benchmark/assets/large.json /app/large.json
EXPOSE 8080
CMD ["./server"]

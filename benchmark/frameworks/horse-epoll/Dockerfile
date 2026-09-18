# Horse (epoll provider) contender - built from source inside Docker, cloning
# the public upstream fresh at build time (github.com/HashLoad/horse, latest
# commit on the default branch - the epoll provider is not necessarily in a
# tagged release yet). Horse.Provider.Epoll.pas already has {$IFDEF FPC}
# guards throughout; only bench-horse.dpr (this benchmark's own wrapper, not
# part of Horse itself) needed porting to build under FPC.
#
#   docker build -f benchmark/frameworks/horse-epoll/Dockerfile -t bench-horse .

FROM poseidon-bench/fpc-trunk AS build

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 https://github.com/HashLoad/horse.git horse
COPY benchmark/frameworks/horse-epoll/bench-horse.dpr ./bench-horse.dpr
RUN mkdir -p ./out

RUN FPCVER="$(cat /opt/fpc-trunk/VERSION)" \
 && /opt/fpc-trunk/lib/fpc/"$FPCVER"/ppcx64 -Tlinux -O2 -vw \
      -MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes \
      -dHORSE_PROVIDER_EPOLL \
      -Fu/opt/fpc-trunk/lib/fpc/"$FPCVER"/units/x86_64-linux/rtl \
      -Fu"/opt/fpc-trunk/lib/fpc/$FPCVER/units/x86_64-linux/*" \
      -Fuhorse/src \
      -FU./out -FE./out \
      -o./out/bench_horse \
      ./bench-horse.dpr \
 && test -x ./out/bench_horse

FROM debian:12-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libssl3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/out/bench_horse /app/server
COPY benchmark/assets/large.json /app/large.json
EXPOSE 8080
CMD ["./server"]

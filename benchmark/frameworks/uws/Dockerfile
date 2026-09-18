# ─── Build stage ──────────────────────────────────────────────────────────────
FROM gcc:13 AS build
WORKDIR /src

RUN apt-get update && \
    apt-get install -y --no-install-recommends git make zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# uWebSockets vendors uSockets as a submodule. Pin a known-good tag.
# Init ONLY the uSockets submodule (non-recursive): its nested boringssl/lsquic
# submodules are huge and unneeded for a plain-HTTP (WITH_OPENSSL=0) build.
RUN git clone --depth 1 --branch v20.62.0 \
        https://github.com/uNetworking/uWebSockets.git && \
    cd uWebSockets && \
    git submodule update --init --depth 1 uSockets

# Build uSockets (C event loop). No SSL: we only serve plain HTTP/1.1.
RUN cd uWebSockets/uSockets && make WITH_OPENSSL=0

COPY main.cpp ./

# Release build: -O3 + LTO. Link the static uSockets archive and zlib.
# Statically link libstdc++/libgcc/zlib so the runtime stage needs only glibc.
RUN g++ -O3 -flto -std=c++17 \
        -IuWebSockets/src -IuWebSockets/uSockets/src \
        -o /server main.cpp uWebSockets/uSockets/uSockets.a \
        -static-libgcc -static-libstdc++ -l:libz.a -lpthread

# ─── Runtime stage ────────────────────────────────────────────────────────────
FROM debian:stable-slim AS runtime
WORKDIR /app
COPY --from=build /server /usr/local/bin/server
# Baked-in payload for GET /json-large. Read at startup (cwd is /app).
COPY large.json ./large.json
EXPOSE 8080
CMD ["server"]

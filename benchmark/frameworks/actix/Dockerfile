# ─── Build stage ──────────────────────────────────────────────────────────────
FROM rust:1-slim AS build
WORKDIR /app

# Cache dependencies first
COPY Cargo.toml ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src

# Build the real binary
COPY large.json ./large.json
COPY src ./src
RUN touch src/main.rs && cargo build --release

# ─── Runtime stage ──────────────────────────────────────────────────────────────
FROM debian:stable-slim AS runtime
WORKDIR /app
COPY --from=build /app/target/release/server /usr/local/bin/server
EXPOSE 8080
CMD ["server"]

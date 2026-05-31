FROM debian:bookworm-slim

# Runtime dependencies for Poseidon (epoll, OpenSSL)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libssl3 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Binary is mounted or copied from assets/ at compose-up time
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

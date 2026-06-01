FROM debian:bookworm-slim

# Runtime dependencies for Horse/CrossSocket
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libssl3 ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

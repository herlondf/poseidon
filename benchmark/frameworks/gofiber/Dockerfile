# ─── Build stage ──────────────────────────────────────────────────────────────
FROM golang:alpine AS build
WORKDIR /app

# Resolve dependencies first (cached)
COPY go.mod ./
RUN go mod download github.com/gofiber/fiber/v2 || true

# Build the static binary
COPY . .
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /server .

# ─── Runtime stage ──────────────────────────────────────────────────────────────
FROM gcr.io/distroless/static AS runtime
COPY --from=build /server /server
EXPOSE 8080
ENTRYPOINT ["/server"]

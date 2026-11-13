# syntax=docker/dockerfile:1
# API-сервер для VDS. Локальная разработка этот образ не использует.

FROM golang:1.27-alpine AS build
WORKDIR /src

# Сначала зависимости — слой кэшируется, пока не меняется go.mod/go.sum.
COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
    -o /out/server ./cmd/server

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata \
    && adduser -D -u 10001 app

COPY --from=build /out/server /server
USER app
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
    CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1

ENTRYPOINT ["/server"]

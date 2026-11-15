FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tripthatshit .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates wget && \
    addgroup -g 1000 app && adduser -D -u 1000 -G app app
COPY --from=build /out/tripthatshit /usr/local/bin/tripthatshit
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/tripthatshit"]

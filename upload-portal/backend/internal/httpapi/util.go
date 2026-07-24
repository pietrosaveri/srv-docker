package httpapi

import (
	"net"
	"net/http"
	"strings"
)

// clientIP prefers the first hop of X-Forwarded-For (set by the Caddy
// reverse proxy) and falls back to the raw remote address.
func clientIP(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		parts := strings.Split(fwd, ",")
		return strings.TrimSpace(parts[0])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// sanitizeFilename strips characters that would break a Content-Disposition
// header value.
func sanitizeFilename(name string) string {
	name = strings.ReplaceAll(name, "\r", "")
	name = strings.ReplaceAll(name, "\n", "")
	name = strings.ReplaceAll(name, `"`, "'")
	if name == "" {
		return "download"
	}
	return name
}

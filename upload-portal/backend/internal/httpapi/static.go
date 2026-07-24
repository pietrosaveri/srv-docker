package httpapi

import (
	"io/fs"
	"net/http"
	"path"
	"strings"
)

// staticHandler serves the embedded React build, falling back to
// index.html for any path that isn't a real asset so client-side routing
// (/admin, /u/:token) works on a hard refresh.
func (s *Server) staticHandler() http.Handler {
	fileServer := http.FileServer(http.FS(s.Static))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}

		cleaned := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
		if cleaned == "" {
			cleaned = "index.html"
		}

		if info, err := fs.Stat(s.Static, cleaned); err != nil || info.IsDir() {
			r = r.Clone(r.Context())
			r.URL.Path = "/"
		}
		fileServer.ServeHTTP(w, r)
	})
}

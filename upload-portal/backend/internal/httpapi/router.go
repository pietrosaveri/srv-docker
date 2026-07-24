// Package httpapi wires the HTTP routes for the admin API, the public
// upload API, and the embedded frontend SPA.
package httpapi

import (
	"database/sql"
	"io/fs"
	"net/http"

	"uploadportal/internal/auth"
	"uploadportal/internal/uploads"
)

type Server struct {
	DB            *sql.DB
	Auth          *auth.Service
	Storage       *uploads.Storage
	Static        fs.FS
	PublicBaseURL string
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/admin/status", s.handleAdminStatus)
	mux.HandleFunc("POST /api/admin/setup", s.handleAdminSetup)
	mux.HandleFunc("POST /api/admin/login", s.handleAdminLogin)
	mux.HandleFunc("POST /api/admin/logout", s.handleAdminLogout)

	mux.HandleFunc("POST /api/admin/links", s.Auth.RequireAdmin(s.handleCreateLink))
	mux.HandleFunc("GET /api/admin/links", s.Auth.RequireAdmin(s.handleListLinks))
	mux.HandleFunc("PATCH /api/admin/links/{id}", s.Auth.RequireAdmin(s.handleUpdateLink))
	mux.HandleFunc("DELETE /api/admin/links/{id}", s.Auth.RequireAdmin(s.handleDeleteLink))
	mux.HandleFunc("GET /api/admin/links/{id}/download.zip", s.Auth.RequireAdmin(s.handleDownloadLinkZip))

	mux.HandleFunc("GET /api/admin/uploads", s.Auth.RequireAdmin(s.handleListUploads))
	mux.HandleFunc("DELETE /api/admin/uploads/{id}", s.Auth.RequireAdmin(s.handleDeleteUpload))
	mux.HandleFunc("GET /api/admin/uploads/{id}/download", s.Auth.RequireAdmin(s.handleDownloadUpload))
	mux.HandleFunc("GET /api/admin/thumbnails/{id}", s.Auth.RequireAdmin(s.handleThumbnail))

	mux.HandleFunc("GET /api/u/{token}/info", s.handleClientInfo)
	mux.HandleFunc("POST /api/u/{token}/upload", s.handleClientUpload)

	mux.Handle("/", s.staticHandler())

	return mux
}

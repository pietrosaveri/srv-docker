package httpapi

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"uploadportal/internal/archive"
	"uploadportal/internal/auth"
	"uploadportal/internal/links"
	"uploadportal/internal/uploads"
)

func (s *Server) handleAdminStatus(w http.ResponseWriter, r *http.Request) {
	setUp, err := s.Auth.IsSetUp()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"setup_required": !setUp,
		"authenticated":  s.Auth.IsAuthenticated(r),
	})
}

func (s *Server) handleAdminSetup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if len(body.Password) < 8 {
		writeError(w, http.StatusBadRequest, "password must be at least 8 characters")
		return
	}

	if err := s.Auth.Setup(body.Password); err != nil {
		if errors.Is(err, auth.ErrAlreadySetUp) {
			writeError(w, http.StatusConflict, "admin password is already set")
			return
		}
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleAdminLogin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	token, err := s.Auth.Login(clientIP(r), body.Password)
	if err != nil {
		switch {
		case errors.Is(err, auth.ErrNotSetUp):
			writeError(w, http.StatusConflict, "admin password has not been set up yet")
		case errors.Is(err, auth.ErrWrongPassword):
			writeError(w, http.StatusUnauthorized, "wrong password")
		default:
			writeError(w, http.StatusTooManyRequests, err.Error())
		}
		return
	}

	auth.SetSessionCookie(w, token)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleAdminLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(auth.CookieName); err == nil {
		_ = s.Auth.Logout(c.Value)
	}
	auth.ClearSessionCookie(w)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) linkJSON(l links.Link, uploadCount, totalSize int64) map[string]any {
	return map[string]any{
		"id":                         l.ID,
		"token":                      l.Token,
		"title":                      l.Title,
		"url":                        strings.TrimRight(s.PublicBaseURL, "/") + "/u/" + l.Token,
		"created_at":                 l.CreatedAt,
		"expires_at":                 l.ExpiresAt,
		"max_files":                  l.MaxFiles,
		"max_size_bytes":             l.MaxSizeBytes,
		"disable_after_first_upload": l.DisableAfterFirstUpload,
		"has_password":               l.HasPassword,
		"active":                     l.Active,
		"upload_count":               uploadCount,
		"total_size":                 totalSize,
	}
}

func (s *Server) handleCreateLink(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title                   string   `json:"title"`
		ExpiresInDays           *int64   `json:"expires_in_days"`
		MaxFiles                *int64   `json:"max_files"`
		MaxSizeGB               *float64 `json:"max_size_gb"`
		Password                string   `json:"password"`
		DisableAfterFirstUpload bool     `json:"disable_after_first_upload"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	title := strings.TrimSpace(req.Title)
	if title == "" {
		writeError(w, http.StatusBadRequest, "title is required")
		return
	}

	var expiresAt *time.Time
	if req.ExpiresInDays != nil && *req.ExpiresInDays > 0 {
		t := time.Now().UTC().Add(time.Duration(*req.ExpiresInDays) * 24 * time.Hour)
		expiresAt = &t
	}
	var maxSizeBytes *int64
	if req.MaxSizeGB != nil && *req.MaxSizeGB > 0 {
		b := int64(*req.MaxSizeGB * 1024 * 1024 * 1024)
		maxSizeBytes = &b
	}

	link, err := links.Create(s.DB, links.CreateParams{
		Title:                   title,
		ExpiresAt:               expiresAt,
		MaxFiles:                req.MaxFiles,
		MaxSizeBytes:            maxSizeBytes,
		DisableAfterFirstUpload: req.DisableAfterFirstUpload,
		Password:                req.Password,
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, s.linkJSON(*link, 0, 0))
}

func (s *Server) handleListLinks(w http.ResponseWriter, r *http.Request) {
	stats, err := links.List(s.DB)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]map[string]any, 0, len(stats))
	for _, st := range stats {
		out = append(out, s.linkJSON(st.Link, st.UploadCount, st.TotalSize))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleUpdateLink(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid link id")
		return
	}
	var req struct {
		Active *bool `json:"active"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Active != nil {
		if err := links.SetActive(s.DB, id, *req.Active); err != nil {
			if errors.Is(err, links.ErrNotFound) {
				writeError(w, http.StatusNotFound, "link not found")
				return
			}
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}

	link, err := links.GetByID(s.DB, id)
	if errors.Is(err, links.ErrNotFound) {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	count, size, err := uploads.Stats(s.DB, id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.linkJSON(*link, count, size))
}

func (s *Server) handleDeleteLink(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid link id")
		return
	}
	link, err := links.GetByID(s.DB, id)
	if errors.Is(err, links.ErrNotFound) {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	ups, err := uploads.ListByLink(s.DB, id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, u := range ups {
		if err := s.Storage.DeleteThumbnail(u.ID); err != nil {
			log.Printf("delete thumbnail %d: %v", u.ID, err)
		}
	}
	if err := s.Storage.DeleteLinkDir(link.Token); err != nil {
		log.Printf("delete link dir %s: %v", link.Token, err)
	}

	if err := links.Delete(s.DB, id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleDownloadLinkZip(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid link id")
		return
	}
	link, err := links.GetByID(s.DB, id)
	if errors.Is(err, links.ErrNotFound) {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	ups, err := uploads.ListByLink(s.DB, id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+sanitizeFilename(link.Title)+`.zip"`)
	if err := archive.WriteZip(w, ups); err != nil {
		log.Printf("zip stream for link %d failed: %v", id, err)
	}
}

func (s *Server) handleListUploads(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var linkID *int64
	if v := q.Get("link_id"); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid link_id")
			return
		}
		linkID = &id
	}
	limit := 50
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}
	offset := 0
	if v := q.Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			offset = n
		}
	}

	ups, err := uploads.ListRecent(s.DB, linkID, limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]map[string]any, 0, len(ups))
	for _, u := range ups {
		out = append(out, uploadJSON(u))
	}
	writeJSON(w, http.StatusOK, out)
}

func uploadJSON(u uploads.Upload) map[string]any {
	return map[string]any{
		"id":               u.ID,
		"link_id":          u.LinkID,
		"filename":         u.Filename,
		"relative_path":    u.RelativePath,
		"size":             u.Size,
		"mime":             u.Mime,
		"uploaded_at":      u.UploadedAt,
		"thumbnail_status": u.ThumbnailStatus,
	}
}

func (s *Server) handleDeleteUpload(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid upload id")
		return
	}
	u, err := uploads.GetByID(s.DB, id)
	if errors.Is(err, uploads.ErrNotFound) {
		writeError(w, http.StatusNotFound, "upload not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	if err := s.Storage.DeleteFile(u.StoragePath); err != nil {
		log.Printf("delete file %s: %v", u.StoragePath, err)
	}
	if err := s.Storage.DeleteThumbnail(u.ID); err != nil {
		log.Printf("delete thumbnail %d: %v", u.ID, err)
	}
	if err := uploads.Delete(s.DB, id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleDownloadUpload(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid upload id")
		return
	}
	u, err := uploads.GetByID(s.DB, id)
	if errors.Is(err, uploads.ErrNotFound) {
		writeError(w, http.StatusNotFound, "upload not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Disposition", `attachment; filename="`+sanitizeFilename(u.Filename)+`"`)
	http.ServeFile(w, r, u.StoragePath)
}

func (s *Server) handleThumbnail(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimSuffix(r.PathValue("id"), ".jpg")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid upload id")
		return
	}
	u, err := uploads.GetByID(s.DB, id)
	if err != nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	if u.ThumbnailStatus != uploads.ThumbnailReady {
		writeError(w, http.StatusNotFound, "thumbnail not ready")
		return
	}
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeFile(w, r, s.Storage.ThumbnailPath(id))
}

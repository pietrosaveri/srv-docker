package httpapi

import (
	"errors"
	"io"
	"log"
	"net/http"
	"path/filepath"

	"uploadportal/internal/auth"
	"uploadportal/internal/links"
	"uploadportal/internal/thumbnails"
	"uploadportal/internal/uploads"
)

func (s *Server) handleClientInfo(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	link, err := links.GetByToken(s.DB, token)
	if errors.Is(err, links.ErrNotFound) {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	count, size, err := uploads.Stats(s.DB, link.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	state := link.EvaluateState(count, size)

	writeJSON(w, http.StatusOK, map[string]any{
		"title":             link.Title,
		"active":            state.Active,
		"expired":           state.Expired,
		"requires_password": state.RequiresPassword,
		"files_remaining":   state.FilesRemaining,
		"bytes_remaining":   state.BytesRemaining,
	})
}

func (s *Server) handleClientUpload(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	link, err := links.GetByToken(s.DB, token)
	if errors.Is(err, links.ErrNotFound) {
		writeError(w, http.StatusNotFound, "link not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	count, size, err := uploads.Stats(s.DB, link.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	state := link.EvaluateState(count, size)

	if ok, reason := state.CanAcceptUpload(0); !ok {
		writeError(w, http.StatusForbidden, reason)
		return
	}

	mr, err := r.MultipartReader()
	if err != nil {
		writeError(w, http.StatusBadRequest, "expected multipart/form-data")
		return
	}

	var relativePath, password string
	var saved *uploads.Upload

	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			writeError(w, http.StatusBadRequest, "malformed upload request")
			return
		}

		switch part.FormName() {
		case "relative_path":
			b, _ := io.ReadAll(io.LimitReader(part, 4096))
			relativePath = string(b)
		case "password":
			b, _ := io.ReadAll(io.LimitReader(part, 4096))
			password = string(b)
		case "file":
			if relativePath == "" {
				relativePath = part.FileName()
			}
			if state.RequiresPassword && !auth.VerifySecret(password, link.PasswordSalt, link.PasswordHash) {
				part.Close()
				writeError(w, http.StatusUnauthorized, "password required or incorrect")
				return
			}

			var maxSize int64
			if state.BytesRemaining != nil {
				maxSize = *state.BytesRemaining
			}
			absPath, written, mimeType, err := s.Storage.SaveUpload(token, relativePath, part, maxSize)
			part.Close()
			if err != nil {
				if errors.Is(err, uploads.ErrTooLarge) {
					writeError(w, http.StatusRequestEntityTooLarge, "file exceeds the link's remaining size limit")
					return
				}
				if errors.Is(err, uploads.ErrPathTraversal) {
					writeError(w, http.StatusBadRequest, "invalid file path")
					return
				}
				writeError(w, http.StatusInternalServerError, err.Error())
				return
			}

			thumbStatus := uploads.ThumbnailNone
			kind := thumbnails.Kind(mimeType)
			if kind != "" {
				thumbStatus = uploads.ThumbnailPending
			}

			u, err := uploads.Insert(s.DB, link.ID, filepath.Base(relativePath), relativePath, written, mimeType, absPath, thumbStatus)
			if err != nil {
				writeError(w, http.StatusInternalServerError, err.Error())
				return
			}
			if kind != "" {
				go s.generateThumbnail(u.ID, mimeType, absPath)
			}
			if link.DisableAfterFirstUpload {
				if err := links.DisableAfterUpload(s.DB, link.ID); err != nil {
					log.Printf("disable-after-first-upload for link %d: %v", link.ID, err)
				}
			}
			saved = u
		default:
			io.Copy(io.Discard, part)
			part.Close()
		}
	}

	if saved == nil {
		writeError(w, http.StatusBadRequest, "no file found in upload request")
		return
	}
	writeJSON(w, http.StatusCreated, uploadJSON(*saved))
}

func (s *Server) generateThumbnail(uploadID int64, mimeType, srcPath string) {
	dest := s.Storage.ThumbnailPath(uploadID)
	status := uploads.ThumbnailReady
	if err := thumbnails.Generate(mimeType, srcPath, dest); err != nil {
		log.Printf("thumbnail generation failed for upload %d: %v", uploadID, err)
		status = uploads.ThumbnailFailed
	}
	if err := uploads.SetThumbnailStatus(s.DB, uploadID, status); err != nil {
		log.Printf("set thumbnail status for upload %d: %v", uploadID, err)
	}
}

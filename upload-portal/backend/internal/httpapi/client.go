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

			// The file is now fully on disk. Re-check the link's limits
			// against the committed state under a per-link lock and record
			// it atomically — see recordUpload for why the earlier check
			// alone is not enough under concurrent uploads.
			u, reason, err := s.recordUpload(link, relativePath, absPath, mimeType, written, thumbStatus)
			if err != nil {
				s.Storage.DeleteFile(absPath)
				if errors.Is(err, errUploadRejected) {
					writeError(w, http.StatusForbidden, reason)
					return
				}
				writeError(w, http.StatusInternalServerError, err.Error())
				return
			}
			if kind != "" {
				go s.generateThumbnail(u.ID, mimeType, absPath)
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

// errUploadRejected signals that a fully-uploaded file was refused because the
// link's limits (max files / max size / active / expiry) no longer allow it.
var errUploadRejected = errors.New("upload rejected by link limits")

// recordUpload atomically re-evaluates the link's limits against the current
// committed count/size and, if the file still fits, inserts it. The per-link
// lock serializes this critical section so concurrent uploads to the same link
// cannot each observe the same pre-insert state and collectively exceed the
// caps. On rejection it returns errUploadRejected with a human-readable reason;
// the caller is responsible for removing the already-written file.
func (s *Server) recordUpload(link *links.Link, relativePath, absPath, mimeType string, written int64, thumbStatus string) (*uploads.Upload, string, error) {
	unlock := s.linkLocks.lock(link.ID)
	defer unlock()

	fresh, err := links.GetByID(s.DB, link.ID)
	if err != nil {
		return nil, "", err
	}
	count, size, err := uploads.Stats(s.DB, link.ID)
	if err != nil {
		return nil, "", err
	}
	if ok, reason := fresh.EvaluateState(count, size).CanAcceptUpload(written); !ok {
		return nil, reason, errUploadRejected
	}

	u, err := uploads.Insert(s.DB, link.ID, filepath.Base(relativePath), relativePath, written, mimeType, absPath, thumbStatus)
	if err != nil {
		return nil, "", err
	}
	if fresh.DisableAfterFirstUpload {
		if err := links.DisableAfterUpload(s.DB, link.ID); err != nil {
			log.Printf("disable-after-first-upload for link %d: %v", link.ID, err)
		}
	}
	return u, "", nil
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

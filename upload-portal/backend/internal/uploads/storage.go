package uploads

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

var ErrPathTraversal = errors.New("invalid relative path")
var ErrTooLarge = errors.New("file exceeds the allowed size")

type Storage struct {
	BaseDir string
}

func NewStorage(baseDir string) *Storage {
	return &Storage{BaseDir: baseDir}
}

func (s *Storage) FilesDir() string       { return filepath.Join(s.BaseDir, "files") }
func (s *Storage) ThumbnailsDir() string  { return filepath.Join(s.BaseDir, "thumbnails") }
func (s *Storage) DBPath() string         { return filepath.Join(s.BaseDir, "db", "upload.db") }
func (s *Storage) LinkDir(token string) string {
	return filepath.Join(s.FilesDir(), token)
}

func (s *Storage) ThumbnailPath(uploadID int64) string {
	return filepath.Join(s.ThumbnailsDir(), fmt.Sprintf("%d.jpg", uploadID))
}

func (s *Storage) EnsureDirs() error {
	for _, dir := range []string{s.FilesDir(), s.ThumbnailsDir(), filepath.Dir(s.DBPath())} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	return nil
}

// resolveRelativePath sanitizes a client-supplied relative path (which may
// include folder components from a drag-and-drop folder upload) and returns
// an absolute path guaranteed to live inside linkDir.
func resolveRelativePath(linkDir, relativePath string) (string, error) {
	relativePath = strings.ReplaceAll(relativePath, "\\", "/")
	relativePath = strings.TrimPrefix(relativePath, "/")
	if relativePath == "" {
		return "", ErrPathTraversal
	}

	clean := filepath.Clean(filepath.Join(string(filepath.Separator), relativePath))
	// clean is now an absolute-rooted, traversal-free path like "/a/b/c.jpg"
	full := filepath.Join(linkDir, clean)

	linkDirWithSep := filepath.Clean(linkDir) + string(filepath.Separator)
	if !strings.HasPrefix(full+string(filepath.Separator), linkDirWithSep) {
		return "", ErrPathTraversal
	}
	return full, nil
}

// SaveUpload streams r to disk under linkDir/relativePath, enforcing maxSize
// (0 = unlimited) while writing. It returns the absolute path, final size and
// a sniffed MIME type.
func (s *Storage) SaveUpload(token, relativePath string, r io.Reader, maxSize int64) (absPath string, size int64, mimeType string, err error) {
	linkDir := s.LinkDir(token)
	dest, err := resolveRelativePath(linkDir, relativePath)
	if err != nil {
		return "", 0, "", err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", 0, "", err
	}

	f, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return "", 0, "", err
	}
	defer f.Close()

	var limited io.Reader = r
	if maxSize > 0 {
		// Read one byte past the limit so we can tell "exactly at the cap"
		// apart from "over the cap" once copying finishes.
		limited = io.LimitReader(r, maxSize+1)
	}

	sniffBuf := make([]byte, 512)
	n, readErr := io.ReadFull(limited, sniffBuf)
	if readErr != nil && readErr != io.ErrUnexpectedEOF && readErr != io.EOF {
		os.Remove(dest)
		return "", 0, "", readErr
	}
	sniffBuf = sniffBuf[:n]
	mimeType = http.DetectContentType(sniffBuf)

	written := int64(0)
	if n > 0 {
		w, err := f.Write(sniffBuf)
		if err != nil {
			os.Remove(dest)
			return "", 0, "", err
		}
		written += int64(w)
	}

	if readErr == nil {
		copied, err := io.Copy(f, limited)
		if err != nil {
			os.Remove(dest)
			return "", 0, "", err
		}
		written += copied
	}

	if maxSize > 0 && written > maxSize {
		os.Remove(dest)
		return "", 0, "", ErrTooLarge
	}

	return dest, written, mimeType, nil
}

func (s *Storage) DeleteFile(path string) error {
	err := os.Remove(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (s *Storage) DeleteThumbnail(uploadID int64) error {
	return s.DeleteFile(s.ThumbnailPath(uploadID))
}

// DeleteLinkDir removes an entire link's upload directory (used when a link
// itself is deleted).
func (s *Storage) DeleteLinkDir(token string) error {
	err := os.RemoveAll(s.LinkDir(token))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

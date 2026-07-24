// Package archive streams a link's uploads as a ZIP file directly to an
// http.ResponseWriter, preserving the relative folder structure.
package archive

import (
	"archive/zip"
	"io"
	"net/http"
	"os"

	"uploadportal/internal/uploads"
)

func WriteZip(w http.ResponseWriter, files []uploads.Upload) error {
	zw := zip.NewWriter(w)
	defer zw.Close()

	for _, u := range files {
		entry, err := zw.Create(u.RelativePath)
		if err != nil {
			return err
		}
		src, err := os.Open(u.StoragePath)
		if err != nil {
			continue // file went missing on disk; skip rather than fail the whole archive
		}
		_, err = io.Copy(entry, src)
		src.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

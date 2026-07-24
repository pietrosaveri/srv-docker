// Package thumbnails generates a small JPEG preview for an uploaded file:
// resized directly for images, a single extracted frame for video (ffmpeg),
// and a rendered first page for PDFs (poppler's pdftoppm).
package thumbnails

import (
	"context"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/gif"
	_ "image/png"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/image/draw"
)

const (
	maxThumbWidth = 400
	genTimeout    = 30 * time.Second
)

// Kind classifies a MIME type into a thumbnail strategy, or "" if unsupported.
func Kind(mimeType string) string {
	switch {
	case strings.HasPrefix(mimeType, "image/"):
		return "image"
	case strings.HasPrefix(mimeType, "video/"):
		return "video"
	case mimeType == "application/pdf":
		return "pdf"
	default:
		return ""
	}
}

// Generate writes a JPEG thumbnail for srcPath to destPath based on mimeType.
func Generate(mimeType, srcPath, destPath string) error {
	switch Kind(mimeType) {
	case "image":
		return generateFromImage(srcPath, destPath)
	case "video":
		return generateFromVideo(srcPath, destPath)
	case "pdf":
		return generateFromPDF(srcPath, destPath)
	default:
		return fmt.Errorf("unsupported mime type %q", mimeType)
	}
}

func generateFromImage(srcPath, destPath string) error {
	f, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer f.Close()

	src, _, err := image.Decode(f)
	if err != nil {
		return err
	}

	bounds := src.Bounds()
	w, h := bounds.Dx(), bounds.Dy()
	if w > maxThumbWidth {
		h = h * maxThumbWidth / w
		w = maxThumbWidth
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, bounds, draw.Over, nil)

	out, err := os.Create(destPath)
	if err != nil {
		return err
	}
	defer out.Close()
	return jpeg.Encode(out, dst, &jpeg.Options{Quality: 82})
}

func generateFromVideo(srcPath, destPath string) error {
	ctx, cancel := context.WithTimeout(context.Background(), genTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ffmpeg",
		"-y",
		"-ss", "00:00:01",
		"-i", srcPath,
		"-frames:v", "1",
		"-vf", fmt.Sprintf("scale=%d:-1", maxThumbWidth),
		destPath,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ffmpeg: %w: %s", err, string(out))
	}
	return nil
}

func generateFromPDF(srcPath, destPath string) error {
	ctx, cancel := context.WithTimeout(context.Background(), genTimeout)
	defer cancel()

	tmpDir, err := os.MkdirTemp("", "pdf-thumb-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	prefix := filepath.Join(tmpDir, "page")
	cmd := exec.CommandContext(ctx, "pdftoppm",
		"-jpeg", "-f", "1", "-l", "1", "-scale-to", fmt.Sprintf("%d", maxThumbWidth),
		srcPath, prefix,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("pdftoppm: %w: %s", err, string(out))
	}

	matches, err := filepath.Glob(prefix + "*.jpg")
	if err != nil {
		return err
	}
	if len(matches) == 0 {
		return fmt.Errorf("pdftoppm produced no output")
	}

	data, err := os.ReadFile(matches[0])
	if err != nil {
		return err
	}
	return os.WriteFile(destPath, data, 0o644)
}

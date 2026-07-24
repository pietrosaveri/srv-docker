package main

import (
	"embed"
	"io/fs"
	"log"
	"net/http"
	"os"
	"time"

	"uploadportal/internal/auth"
	"uploadportal/internal/db"
	"uploadportal/internal/httpapi"
	"uploadportal/internal/uploads"
)

//go:embed all:web/dist
var embeddedFrontend embed.FS

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	dataDir := getenv("DATA_DIR", "/data")
	port := getenv("PORT", "8080")
	publicBaseURL := getenv("PUBLIC_BASE_URL", "https://upload.pietroserver.duckdns.org")

	storage := uploads.NewStorage(dataDir)
	if err := storage.EnsureDirs(); err != nil {
		log.Fatalf("creating data directories: %v", err)
	}

	sqlDB, err := db.Open(storage.DBPath())
	if err != nil {
		log.Fatalf("opening database: %v", err)
	}
	defer sqlDB.Close()

	distFS, err := fs.Sub(embeddedFrontend, "web/dist")
	if err != nil {
		log.Fatalf("loading embedded frontend: %v", err)
	}

	server := &httpapi.Server{
		DB:            sqlDB,
		Auth:          auth.New(sqlDB),
		Storage:       storage,
		Static:        distFS,
		PublicBaseURL: publicBaseURL,
	}

	httpServer := &http.Server{
		Addr:              ":" + port,
		Handler:           server.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("upload-portal listening on :%s (data dir %s)", port, dataDir)
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

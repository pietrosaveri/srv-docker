import { useEffect, useState, useCallback } from "react";
import { useParams } from "react-router-dom";
import DropZone from "./DropZone.jsx";
import { uploadFile, runQueue } from "./uploadClient.js";
import { formatBytes } from "./format.js";

export default function UploadPage() {
  const { token } = useParams();
  const [info, setInfo] = useState(null);
  const [error, setError] = useState("");
  const [password, setPassword] = useState("");
  const [queue, setQueue] = useState([]);
  const [uploading, setUploading] = useState(false);

  useEffect(() => {
    fetch(`/api/u/${token}/info`)
      .then(async (res) => {
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || "link not found");
        setInfo(data);
      })
      .catch((e) => setError(e.message));
  }, [token]);

  const addFiles = useCallback((entries) => {
    setQueue((q) => [...q, ...entries.map((e) => ({ ...e, progress: 0, status: "queued", error: null }))]);
  }, []);

  const startUpload = async () => {
    setUploading(true);
    const items = queue.map((item, idx) => ({
      run: () =>
        uploadFile({
          token,
          file: item.file,
          relativePath: item.relativePath,
          password,
          onProgress: (p) =>
            setQueue((q) => q.map((it, i) => (i === idx ? { ...it, progress: p, status: "uploading" } : it))),
        })
          .then(() => setQueue((q) => q.map((it, i) => (i === idx ? { ...it, progress: 1, status: "done" } : it))))
          .catch((err) =>
            setQueue((q) => q.map((it, i) => (i === idx ? { ...it, status: "error", error: err.message } : it))),
          ),
    }));
    await runQueue(items, 3);
    setUploading(false);
  };

  if (error) {
    return (
      <div className="client-page">
        <div className="client-card card">
          <h1>Link unavailable</h1>
          <p className="subtitle">{error}</p>
        </div>
      </div>
    );
  }

  if (!info) {
    return (
      <div className="client-page">
        <p className="subtitle">Loading…</p>
      </div>
    );
  }

  if (!info.active || info.expired) {
    return (
      <div className="client-page">
        <div className="client-card card">
          <h1>{info.title}</h1>
          <p className="subtitle">
            {info.expired ? "This link has expired." : "This link is no longer accepting uploads."}
          </p>
        </div>
      </div>
    );
  }

  const allDone = queue.length > 0 && queue.every((q) => q.status === "done");
  const hasErrors = queue.some((q) => q.status === "error");

  return (
    <div className="client-page">
      <div className="client-card">
        <h1>Send files to Pietro</h1>
        <p className="subtitle">{info.title}</p>

        {info.requires_password && (
          <div className="field" style={{ textAlign: "left" }}>
            <label>Password</label>
            <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
          </div>
        )}

        <DropZone onFiles={addFiles} disabled={uploading} />

        {queue.length > 0 && (
          <div className="file-queue">
            {queue.map((item, i) => (
              <div key={i} className={`file-row ${item.status}`} title={item.error || ""}>
                <span className="name">{item.relativePath}</span>
                <span>{formatBytes(item.file.size)}</span>
                <div className="progress-bar">
                  <div style={{ width: `${Math.round(item.progress * 100)}%` }} />
                </div>
              </div>
            ))}
          </div>
        )}

        {queue.length > 0 && !allDone && (
          <button className="btn btn-primary" onClick={startUpload} disabled={uploading}>
            {uploading ? "Uploading…" : `Upload ${queue.length} item${queue.length > 1 ? "s" : ""}`}
          </button>
        )}
        {allDone && !hasErrors && <p className="status-message">All files uploaded. Thank you!</p>}
        {allDone && hasErrors && <p className="status-message">Some files failed — hover a row to see why.</p>}
      </div>
    </div>
  );
}

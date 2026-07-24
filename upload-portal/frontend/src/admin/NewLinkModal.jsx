import { useState } from "react";
import { api } from "./api.js";

export default function NewLinkModal({ onClose, onCreated }) {
  const [title, setTitle] = useState("");
  const [expiresInDays, setExpiresInDays] = useState("7");
  const [maxFiles, setMaxFiles] = useState("");
  const [maxSizeGB, setMaxSizeGB] = useState("");
  const [password, setPassword] = useState("");
  const [disableAfterFirstUpload, setDisableAfterFirstUpload] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    if (!title.trim()) {
      setError("Title is required.");
      return;
    }
    setBusy(true);
    setError("");
    try {
      await api.createLink({
        title: title.trim(),
        expires_in_days: expiresInDays ? Number(expiresInDays) : null,
        max_files: maxFiles ? Number(maxFiles) : null,
        max_size_gb: maxSizeGB ? Number(maxSizeGB) : null,
        password: password || undefined,
        disable_after_first_upload: disableAfterFirstUpload,
      });
      onCreated();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <form className="modal" onClick={(e) => e.stopPropagation()} onSubmit={submit}>
        <h2>New upload link</h2>
        {error && <div className="error-banner">{error}</div>}

        <div className="field">
          <label>Title</label>
          <input
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="Project Photos"
            autoFocus
          />
        </div>

        <div className="field-row">
          <div className="field">
            <label>Expires in (days, blank = never)</label>
            <input type="number" min="0" value={expiresInDays} onChange={(e) => setExpiresInDays(e.target.value)} />
          </div>
          <div className="field">
            <label>Max files (blank = unlimited)</label>
            <input type="number" min="0" value={maxFiles} onChange={(e) => setMaxFiles(e.target.value)} />
          </div>
        </div>

        <div className="field-row">
          <div className="field">
            <label>Max size in GB (blank = unlimited)</label>
            <input
              type="number"
              min="0"
              step="0.1"
              value={maxSizeGB}
              onChange={(e) => setMaxSizeGB(e.target.value)}
            />
          </div>
          <div className="field">
            <label>Password (optional)</label>
            <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
          </div>
        </div>

        <div className="checkbox-row">
          <input
            type="checkbox"
            id="disable-after"
            checked={disableAfterFirstUpload}
            onChange={(e) => setDisableAfterFirstUpload(e.target.checked)}
          />
          <label htmlFor="disable-after" style={{ margin: 0 }}>
            Disable link after first upload
          </label>
        </div>

        <div className="modal-actions">
          <button type="button" className="btn" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className="btn btn-primary" disabled={busy}>
            {busy ? "Creating…" : "Create link"}
          </button>
        </div>
      </form>
    </div>
  );
}

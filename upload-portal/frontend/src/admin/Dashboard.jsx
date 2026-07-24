import { useEffect, useState, useCallback } from "react";
import { api } from "./api.js";
import { formatBytes, formatDate } from "./format.js";
import NewLinkModal from "./NewLinkModal.jsx";
import UploadRow from "./UploadRow.jsx";

export default function Dashboard({ onLogout }) {
  const [links, setLinks] = useState([]);
  const [uploads, setUploads] = useState([]);
  const [showNewLink, setShowNewLink] = useState(false);
  const [error, setError] = useState("");
  const [copiedId, setCopiedId] = useState(null);

  const loadLinks = useCallback(() => {
    api.listLinks().then(setLinks).catch((e) => setError(e.message));
  }, []);
  const loadUploads = useCallback(() => {
    api.listUploads({ limit: 30 }).then(setUploads).catch((e) => setError(e.message));
  }, []);

  useEffect(() => {
    loadLinks();
    loadUploads();
  }, [loadLinks, loadUploads]);

  useEffect(() => {
    const hasPending = uploads.some((u) => u.thumbnail_status === "pending");
    if (!hasPending) return undefined;
    const id = setInterval(loadUploads, 3000);
    return () => clearInterval(id);
  }, [uploads, loadUploads]);

  const copyLink = (link) => {
    navigator.clipboard.writeText(link.url);
    setCopiedId(link.id);
    setTimeout(() => setCopiedId(null), 1500);
  };

  const toggleActive = async (link) => {
    await api.setLinkActive(link.id, !link.active);
    loadLinks();
  };

  const removeLink = async (link) => {
    if (!window.confirm(`Delete link "${link.title}" and all its uploads?`)) return;
    await api.deleteLink(link.id);
    loadLinks();
    loadUploads();
  };

  const removeUpload = async (upload) => {
    if (!window.confirm(`Delete ${upload.filename}?`)) return;
    await api.deleteUpload(upload.id);
    loadUploads();
    loadLinks();
  };

  return (
    <div className="page">
      <div className="section-header">
        <h1>Upload Portal</h1>
        <div style={{ display: "flex", gap: 10 }}>
          <button className="btn btn-primary" onClick={() => setShowNewLink(true)}>
            + New Link
          </button>
          <button className="btn" onClick={onLogout}>
            Log out
          </button>
        </div>
      </div>

      {error && <div className="error-banner">{error}</div>}

      <h2>Active links</h2>
      <div className="link-list">
        {links.length === 0 && (
          <div className="empty-state">No links yet — create one to start receiving files.</div>
        )}
        {links.map((link) => (
          <div key={link.id} className={`card link-item ${link.active ? "" : "inactive"}`}>
            <div>
              <strong>{link.title}</strong>
              <div className="link-url-row">
                <span className="link-url">{link.url}</span>
                <button className="btn btn-small" onClick={() => copyLink(link)}>
                  {copiedId === link.id ? "Copied!" : "Copy link"}
                </button>
              </div>
              <div className="link-meta">
                <span>{link.expires_at ? `expires ${new Date(link.expires_at).toLocaleDateString()}` : "no expiry"}</span>
                <span>{link.upload_count} uploads</span>
                <span>{formatBytes(link.total_size)}</span>
                {link.has_password && <span>🔒 password</span>}
                {!link.active && <span>inactive</span>}
              </div>
            </div>
            <div className="link-actions">
              <a className="btn btn-small" href={`/api/admin/links/${link.id}/download.zip`}>
                Download all
              </a>
              <button className="btn btn-small" onClick={() => toggleActive(link)}>
                {link.active ? "Disable" : "Enable"}
              </button>
              <button className="btn btn-small btn-danger" onClick={() => removeLink(link)}>
                Delete
              </button>
            </div>
          </div>
        ))}
      </div>

      <h2>Recent uploads</h2>
      {uploads.length === 0 ? (
        <div className="empty-state">Nothing uploaded yet.</div>
      ) : (
        <table className="uploads">
          <thead>
            <tr>
              <th></th>
              <th>Name</th>
              <th>Size</th>
              <th>Uploaded</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {uploads.map((u) => (
              <UploadRow
                key={u.id}
                upload={u}
                onDelete={() => removeUpload(u)}
                formatBytes={formatBytes}
                formatDate={formatDate}
              />
            ))}
          </tbody>
        </table>
      )}

      {showNewLink && (
        <NewLinkModal
          onClose={() => setShowNewLink(false)}
          onCreated={() => {
            setShowNewLink(false);
            loadLinks();
          }}
        />
      )}
    </div>
  );
}

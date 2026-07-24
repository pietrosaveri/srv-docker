function iconFor(mime) {
  if (!mime) return "📄";
  if (mime.startsWith("image/")) return "🖼";
  if (mime.startsWith("video/")) return "🎬";
  if (mime === "application/pdf") return "📕";
  return "📄";
}

export default function UploadRow({ upload, onDelete, formatBytes, formatDate }) {
  const thumbUrl = `/api/admin/thumbnails/${upload.id}.jpg`;

  return (
    <tr>
      <td>
        {upload.thumbnail_status === "ready" ? (
          <img className="thumb" src={thumbUrl} alt="" />
        ) : (
          <div className="thumb">{iconFor(upload.mime)}</div>
        )}
      </td>
      <td>{upload.relative_path}</td>
      <td>{formatBytes(upload.size)}</td>
      <td>{formatDate(upload.uploaded_at)}</td>
      <td>
        <div style={{ display: "flex", gap: 8 }}>
          <a className="btn btn-small" href={`/api/admin/uploads/${upload.id}/download`}>
            Download
          </a>
          <button className="btn btn-small btn-danger" onClick={onDelete}>
            Delete
          </button>
        </div>
      </td>
    </tr>
  );
}

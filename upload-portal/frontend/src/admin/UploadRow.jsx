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
      <td className="td-thumb">
        {upload.thumbnail_status === "ready" ? (
          <img className="thumb" src={thumbUrl} alt="" />
        ) : (
          <div className="thumb">{iconFor(upload.mime)}</div>
        )}
      </td>
      <td data-label="Name" className="td-name">
        {upload.relative_path}
      </td>
      <td data-label="Size">{formatBytes(upload.size)}</td>
      <td data-label="Uploaded">{formatDate(upload.uploaded_at)}</td>
      <td className="td-actions">
        <div className="row-actions">
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

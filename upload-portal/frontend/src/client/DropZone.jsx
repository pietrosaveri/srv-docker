import { useRef, useState } from "react";
import { collectFilesFromDataTransfer, collectFilesFromFileList } from "./entryWalk.js";

export default function DropZone({ onFiles, disabled }) {
  const inputRef = useRef(null);
  const [dragging, setDragging] = useState(false);

  const handleDrop = async (e) => {
    e.preventDefault();
    setDragging(false);
    if (disabled) return;
    const entries = await collectFilesFromDataTransfer(e.dataTransfer);
    if (entries.length > 0) onFiles(entries);
  };

  const handleInputChange = (e) => {
    const entries = collectFilesFromFileList(e.target.files);
    if (entries.length > 0) onFiles(entries);
    e.target.value = "";
  };

  return (
    <div
      className={`dropzone ${dragging ? "dragging" : ""}`}
      onDragOver={(e) => {
        e.preventDefault();
        if (!disabled) setDragging(true);
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={handleDrop}
      onClick={() => !disabled && inputRef.current?.click()}
      role="button"
      tabIndex={0}
    >
      <div>Drop files here</div>
      <div className="hint">or click to browse — folders are supported when dropped</div>
      <input ref={inputRef} type="file" multiple style={{ display: "none" }} onChange={handleInputChange} />
    </div>
  );
}

// Uploads one file via XHR (fetch has no upload-progress events) as
// multipart/form-data. relative_path/password must be appended before the
// file field so the backend's streaming multipart reader sees them first.
export function uploadFile({ token, file, relativePath, password, onProgress }) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", `/api/u/${token}/upload`);

    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) onProgress(e.loaded / e.total);
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          resolve(JSON.parse(xhr.responseText));
        } catch {
          resolve(null);
        }
        return;
      }
      let message = `upload failed (${xhr.status})`;
      try {
        message = JSON.parse(xhr.responseText).error || message;
      } catch {
        // ignore
      }
      reject(new Error(message));
    };
    xhr.onerror = () => reject(new Error("network error during upload"));

    const form = new FormData();
    form.append("relative_path", relativePath);
    if (password) form.append("password", password);
    form.append("file", file);
    xhr.send(form);
  });
}

// Runs `items` (each an object with a `run()` promise-returning function)
// with a bounded concurrency instead of firing every upload at once.
export async function runQueue(items, concurrency = 3) {
  let index = 0;
  async function worker() {
    while (index < items.length) {
      const i = index++;
      await items[i].run();
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
}

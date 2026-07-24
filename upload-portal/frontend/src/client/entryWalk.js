// Walks a dropped DataTransfer into a flat list of { file, relativePath },
// recursing into directories via the WebKit entries API so folder structure
// is preserved. Falls back to a flat file list on browsers without it.
export async function collectFilesFromDataTransfer(dataTransfer) {
  const items = dataTransfer.items;
  const topLevelEntries = [];

  if (items) {
    for (let i = 0; i < items.length; i++) {
      const entry = items[i].webkitGetAsEntry ? items[i].webkitGetAsEntry() : null;
      if (entry) topLevelEntries.push(entry);
    }
  }

  if (topLevelEntries.length === 0) {
    const results = [];
    const files = dataTransfer.files || [];
    for (let i = 0; i < files.length; i++) {
      results.push({ file: files[i], relativePath: files[i].name });
    }
    return results;
  }

  const results = [];
  for (const entry of topLevelEntries) {
    await readEntry(entry, "", results);
  }
  return results;
}

function readAllEntries(reader) {
  return new Promise((resolve, reject) => {
    const all = [];
    function readBatch() {
      reader.readEntries((batch) => {
        if (batch.length === 0) {
          resolve(all);
          return;
        }
        all.push(...batch);
        readBatch();
      }, reject);
    }
    readBatch();
  });
}

async function readEntry(entry, path, results) {
  if (entry.isFile) {
    const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
    results.push({ file, relativePath: path + entry.name });
    return;
  }
  if (entry.isDirectory) {
    const children = await readAllEntries(entry.createReader());
    for (const child of children) {
      await readEntry(child, path + entry.name + "/", results);
    }
  }
}

// Converts a plain <input type="file" multiple> FileList into the same
// { file, relativePath } shape used above.
export function collectFilesFromFileList(fileList) {
  const results = [];
  for (let i = 0; i < fileList.length; i++) {
    const file = fileList[i];
    results.push({ file, relativePath: file.webkitRelativePath || file.name });
  }
  return results;
}

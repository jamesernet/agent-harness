const rowKey = (row) => `${row.set}|${row.viewport}|${row.path}`;

/** Re-running one viewport replaces only that viewport's rows, so a run builds up incrementally. */
export function mergeRows(manifest, incoming) {
  const replaced = new Set(incoming.map(rowKey));
  return {
    ...manifest,
    rows: [...manifest.rows.filter((row) => !replaced.has(rowKey(row))), ...incoming],
    updatedAt: new Date().toISOString(),
  };
}

/** Width and height straight from the PNG IHDR chunk — avoids an image dependency. */
export function pngSize(buffer) {
  if (buffer.length < 24 || buffer.readUInt32BE(12) !== 0x49484452) return { width: 0, height: 0 };
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

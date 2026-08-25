import { VIEWPORT_PRESETS } from "./viewports.mjs";

function esc(value) {
  return String(value ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

function cell(row) {
  if (!row) return '<td class="cell empty">-</td>';
  if (!row.file) {
    return `<td class="cell bad"><b>${esc(row.status)}</b><br><small>${esc(row.error)}</small></td>`;
  }
  const mb = ((row.bytes ?? 0) / 1048576).toFixed(1);
  return (
    `<td class="cell"><a href="${esc(row.file)}" target="_blank">` +
    `<img loading="lazy" src="${esc(row.file)}" alt="${esc(row.path)}"></a>` +
    `<div class="meta">${row.width}x${row.height} &middot; ${mb} MB &middot; HTTP ${row.httpStatus ?? "?"}</div></td>`
  );
}

/**
 * One self-contained page laying every captured URL against every viewport.
 * Images are referenced by relative path so it opens straight off disk with no
 * server — which also means it has to stay next to the folders it references.
 */
export function renderContactSheet(manifest) {
  const groups = new Map();
  for (const row of manifest.rows) {
    const key = `${row.set}|${row.path}`;
    if (!groups.has(key)) groups.set(key, { set: row.set, path: row.path, cells: {} });
    groups.get(key).cells[row.viewport] = row;
  }

  const bodyRows = [...groups.values()]
    .sort((a, b) => `${a.set}${a.path}`.localeCompare(`${b.set}${b.path}`))
    .map((group) => {
      const title = VIEWPORT_PRESETS.map((p) => group.cells[p.key]?.title).find(Boolean) ?? "";
      return (
        `<tr><th><span class="tag">${esc(group.set)}</span><br>${esc(group.path)}` +
        `<br><small>${esc(title)}</small></th>` +
        VIEWPORT_PRESETS.map((p) => cell(group.cells[p.key])).join("") +
        "</tr>"
      );
    })
    .join("\n");

  const shots = manifest.rows.filter((row) => row.file).length;
  const failures = manifest.rows.length - shots;

  return `<!doctype html><meta charset="utf-8"><title>Baseline - ${esc(manifest.rootUrl)}</title>
<style>
:root{--bg:#0b0d0c;--surface:#151a17;--border:rgba(255,255,255,.12);--text:#f2efe8;--muted:#a4b0a8;--accent:#6ee7a8}
body{margin:0;padding:24px;background:var(--bg);color:var(--text);font:14px/1.45 ui-sans-serif,system-ui,-apple-system,sans-serif}
h1{font-size:18px;margin:0 0 4px}.sub{color:var(--muted);margin:0 0 16px}
label.toggle{color:var(--muted);cursor:pointer;user-select:none}
table{border-collapse:separate;border-spacing:12px;margin-top:12px}
thead th{color:var(--text);font-weight:600}
th{text-align:left;vertical-align:top;width:210px;color:var(--muted);font-weight:500;word-break:break-word}
th .tag{display:inline-block;padding:1px 6px;border:1px solid var(--border);border-radius:6px;color:var(--accent);font-size:11px}
td.cell{width:340px;vertical-align:top;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:8px}
td.cell img{display:block;width:100%;height:600px;object-fit:cover;object-position:top;border-radius:8px;background:#fff}
#full:checked ~ table td.cell img{height:auto;object-fit:contain}
.meta{color:var(--muted);font-size:11px;margin-top:6px}
td.bad{color:#ff8f8f}td.empty{color:var(--muted);text-align:center}
</style>
<h1>${esc(manifest.rootUrl)} - visual baseline</h1>
<p class="sub">${shots} shots${failures > 0 ? ` &middot; ${failures} failed` : ""} &middot; ${esc(manifest.updatedAt)}</p>
<input type="checkbox" id="full"><label class="toggle" for="full"> show full-length images (heavy)</label>
<table><thead><tr><th>page</th>${VIEWPORT_PRESETS.map((p) => `<th>${p.label}</th>`).join("")}</tr></thead>
<tbody>
${bodyRows}
</tbody></table>`;
}

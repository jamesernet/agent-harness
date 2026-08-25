// Viewport presets. Widths are chosen to sit on the common breakpoints:
// 1440 desktop, 768 iPad portrait, 390 iPhone 14/15.
//
// Note 768 lands above the usual 750px "not phone" breakpoint but below the
// ~990px "show the full nav" one, so many themes render an intermediate state
// there: hamburger menu with a wide layout. That is genuinely what a tablet
// shows; it is not a bug in the capture.

export const VIEWPORT_PRESETS = [
  { key: "desktop", label: "desktop-1440", title: "Desktop", width: 1440, height: 900 },
  { key: "tablet", label: "tablet-768", title: "Tablet", width: 768, height: 1024 },
  { key: "mobile", label: "mobile-390", title: "Mobile", width: 390, height: 844 },
];

export const VIEWPORT_ORDER = VIEWPORT_PRESETS.map((p) => p.key);

export function presetFor(key) {
  const preset = VIEWPORT_PRESETS.find((p) => p.key === key);
  if (!preset) throw new Error(`Unknown viewport preset: ${key}`);
  return preset;
}

/** Matched by width so a manifest reloaded from disk still labels correctly. */
export function viewportLabel(viewport) {
  return VIEWPORT_PRESETS.find((p) => p.width === viewport.width)?.label ?? `w${viewport.width}`;
}

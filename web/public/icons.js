// Line icons drawn as inline SVG (no emoji anywhere in the UI). 24×24, stroked with currentColor,
// so they take the text colour and size of whatever they sit in.

const paths = {
  pencil: ["M12 20h9", "M16.4 3.6a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"],
  check: ["M20 6 9 17l-5-5"],
  close: ["M18 6 6 18", "M6 6l12 12"],
  menu: ["M4 6h16", "M4 12h16", "M4 18h16"],
  link: ["M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7", "M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"],
  phone: ["M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.4 1.8.7 2.7a2 2 0 0 1-.5 2.1L8 9.8a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.7.7a2 2 0 0 1 1.7 2Z"],
  image: ["M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z", "M21 15l-5-5L5 21", "M9 10.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Z"],
  file: ["M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z", "M14 2v6h6"],
  palette: ["M12 22a10 10 0 1 1 10-10c0 2.8-2.2 4-4 4h-1.5a1.5 1.5 0 0 0-1 2.6A1.5 1.5 0 0 1 14.5 21c-.8.6-1.6 1-2.5 1Z", "M7.5 11.5h.01", "M10.5 7.5h.01", "M15.5 8.5h.01"],
  pin: ["M12 17v5", "M9 3h6l-1 6 3 3v2H7v-2l3-3Z"],
  chevronDown: ["M6 9l6 6 6-6"],
  chevronUp: ["M18 15l-6-6-6 6"],
  undo: ["M9 14 4 9l5-5", "M4 9h10.5a5.5 5.5 0 0 1 0 11H11"],
  redo: ["M15 14l5-5-5-5", "M20 9H9.5a5.5 5.5 0 0 0 0 11H13"],
  pages: ["M8 3h11a2 2 0 0 1 2 2v11", "M15 7H5a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2Z"],
  arrowDown: ["M12 5v14", "M19 12l-7 7-7-7"],
  tag: ["M20.6 13.4 13.4 20.6a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8Z", "M7.5 7.5h.01"],
  plus: ["M12 5v14", "M5 12h14"],
  back: ["M15 18l-6-6 6-6"],
  forward: ["M9 18l6-6-6-6"],
  folder: ["M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"],
  clipboard: ["M9 4h6v3H9z", "M9 5H6a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1h-3"],
  map: ["M9 4 3 6v14l6-2 6 2 6-2V4l-6 2-6-2Z", "M9 4v14", "M15 6v14"],
  location: ["M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11Z", "M12 10h.01"],
};

/** An inline SVG icon. Decorative unless given a label (then it's announced as an image). */
export function icon(name, label) {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  for (const [k, v] of Object.entries({ viewBox: "0 0 24 24", width: "1em", height: "1em", fill: "none", stroke: "currentColor",
    "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round", class: `icon icon-${name}` })) svg.setAttribute(k, v);
  if (label) { svg.setAttribute("role", "img"); svg.setAttribute("aria-label", label); } else svg.setAttribute("aria-hidden", "true");
  for (const d of paths[name] ?? []) {
    const p = document.createElementNS(ns, "path");
    p.setAttribute("d", d);
    svg.append(p);
  }
  return svg;
}

/** Swaps every `<span data-icon="name">` under `root` (static HTML and templates) for its icon. */
export function fillIcons(root = document) {
  for (const el of root.querySelectorAll("[data-icon]")) el.replaceWith(icon(el.dataset.icon));
}

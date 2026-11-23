// Regenerates app-icon-1024.svg. Port of the generator in the Claude Design
// project (appIcon in "Agent Collective.dc.html"); the panel layout is seeded,
// so the output is deterministic.
//   node generate-app-icon.mjs > app-icon-1024.svg
const rng = (seed) => { let s = seed >>> 0; return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; }; };
const n = (v) => +v.toFixed(4);

function panels(r) {
  const out = [];
  const sub = (x, y, w, h, d) => {
    if (d >= 2 || r() < (d === 0 ? 0.3 : 0.55)) { out.push([x, y, w, h]); return; }
    const t = 0.35 + r() * 0.3;
    if (r() < 0.5) { sub(x, y, w * t, h, d + 1); sub(x + w * t, y, w * (1 - t), h, d + 1); }
    else { sub(x, y, w, h * t, d + 1); sub(x, y + h * t, w, h * (1 - t), d + 1); }
  };
  const N = 5;
  for (let i = 0; i < N; i++) for (let j = 0; j < N; j++) sub(i / N, j / N, 1 / N, 1 / N, 0);
  return out;
}

function face(m, seam, col, seed, lit) {
  const r = rng(seed), g = 0.007;
  const rects = panels(r).map((p) => {
    const small = p[2] * p[3] < 0.011, on = small && r() < lit, v = r();
    const f = on ? '#86F2B4' : col, o = on ? 0.55 + v * 0.4 : 0.62 + v * 0.38;
    return `<rect x="${n(p[0] + g)}" y="${n(p[1] + g)}" width="${n(Math.max(0, p[2] - 2 * g))}" height="${n(Math.max(0, p[3] - 2 * g))}" fill="${f}" opacity="${n(o)}"/>`;
  });
  return `<g transform="matrix(${m.join(' ')})"><rect width="1" height="1" fill="${seam}"/>${rects.join('')}</g>`;
}

const s = 250, cx = 512, cy = 530, k = 0.866 * s, h = 0.5 * s;
const hex = `M${cx} ${cy - s}L${cx + k} ${cy - h}L${cx + k} ${cy + h}L${cx} ${cy + s}L${cx - k} ${cy + h}L${cx - k} ${cy - h}Z`;
const y = `M${cx - k} ${cy - h}L${cx} ${cy}L${cx + k} ${cy - h}M${cx} ${cy}L${cx} ${cy + s}`;

console.log(`<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3C434A"/><stop offset="1" stop-color="#121517"/></linearGradient><radialGradient id="gl" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#4FE08F" stop-opacity="0.26"/><stop offset="1" stop-color="#4FE08F" stop-opacity="0"/></radialGradient><clipPath id="cl"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath></defs><g clip-path="url(#cl)"><rect x="100" y="100" width="824" height="824" fill="url(#bg)"/><circle cx="512" cy="560" r="400" fill="url(#gl)"/>${face([k, -h, -k, -h, cx, cy].map(n), '#1c2023', '#838D97', 11, 0.06)}${face([-k, -h, 0, s, cx, cy].map(n), '#14171a', '#4E565E', 23, 0.14)}${face([k, -h, 0, s, cx, cy].map(n), '#0d0f11', '#31373D', 37, 0.16)}<path d="${hex}" fill="none" stroke="#fff" stroke-opacity="0.2" stroke-width="3" stroke-linejoin="round"/><path d="${y}" fill="none" stroke="#fff" stroke-opacity="0.32" stroke-width="2.5"/></g><rect x="101" y="101" width="822" height="822" rx="184" fill="none" stroke="#fff" stroke-opacity="0.12" stroke-width="2"/></svg>`);

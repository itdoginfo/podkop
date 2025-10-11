export function svgEl<K extends keyof SVGElementTagNameMap>(
  tag: K,
  attrs: Partial<Record<string, string | number>> = {},
  children: (SVGElement | null | undefined)[] = [],
): SVGElementTagNameMap[K] {
  const NS = 'http://www.w3.org/2000/svg';
  const el = document.createElementNS(NS, tag);

  for (const [k, v] of Object.entries(attrs)) {
    if (v != null) el.setAttribute(k, String(v));
  }

  (Array.isArray(children) ? children : [children])
    .filter(Boolean)
    .forEach((ch) => el.appendChild(ch as SVGElement));

  return el;
}

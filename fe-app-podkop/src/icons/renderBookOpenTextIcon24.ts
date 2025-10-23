import { svgEl } from '../helpers';

export function renderBookOpenTextIcon24() {
  const NS = 'http://www.w3.org/2000/svg';
  return svgEl(
    'svg',
    {
      xmlns: NS,
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: 'lucide lucide-book-open-text-icon lucide-book-open-text',
    },
    [
      svgEl('path', { d: 'M12 7v14' }),
      svgEl('path', { d: 'M16 12h2' }),
      svgEl('path', { d: 'M16 8h2' }),
      svgEl('path', {
        d: 'M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z',
      }),
      svgEl('path', { d: 'M6 12h2' }),
      svgEl('path', { d: 'M6 8h2' }),
    ],
  );
}

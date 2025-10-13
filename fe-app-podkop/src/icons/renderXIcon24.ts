import { svgEl } from '../helpers';

export function renderXIcon24() {
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
      class: 'lucide lucide-x-icon lucide-x',
    },
    [svgEl('path', { d: 'M18 6 6 18' }), svgEl('path', { d: 'm6 6 12 12' })],
  );
}

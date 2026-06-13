import { svgEl } from '../helpers';

export function renderCheckIcon24() {
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
      class: 'lucide lucide-check-icon lucide-check',
    },
    [
      svgEl('path', {
        d: 'M20 6 9 17l-5-5',
      }),
    ],
  );
}

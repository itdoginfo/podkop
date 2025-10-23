import { svgEl } from '../helpers';

export function renderCircleCheckBigIcon24() {
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
      class: 'lucide lucide-circle-check-big-icon lucide-circle-check-big',
    },
    [
      svgEl('path', {
        d: 'M21.801 10A10 10 0 1 1 17 3.335',
      }),
      svgEl('path', {
        d: 'm9 11 3 3L22 4',
      }),
    ],
  );
}

import { svgEl } from '../helpers';

export function renderCircleXIcon24() {
  const NS = 'http://www.w3.org/2000/svg';
  return svgEl(
    'svg',
    {
      xmlns: NS,
      width: '24',
      height: '24',
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: 'lucide lucide-circle-x-icon lucide-circle-x',
    },
    [
      svgEl('circle', {
        cx: '12',
        cy: '12',
        r: '10',
      }),
      svgEl('path', {
        d: 'M15 9L9 15',
      }),
      svgEl('path', {
        d: 'M9 9L15 15',
      }),
    ],
  );
}

import { svgEl } from '../helpers';

export function renderCirclePlayIcon24() {
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
      class: 'lucide lucide-circle-play-icon lucide-circle-play',
    },
    [
      svgEl('path', {
        d: 'M9 9.003a1 1 0 0 1 1.517-.859l4.997 2.997a1 1 0 0 1 0 1.718l-4.997 2.997A1 1 0 0 1 9 14.996z',
      }),
      svgEl('circle', {
        cx: '12',
        cy: '12',
        r: '10',
      }),
    ],
  );
}

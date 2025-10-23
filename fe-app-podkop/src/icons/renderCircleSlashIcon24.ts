import { svgEl } from '../helpers';

export function renderCircleSlashIcon24() {
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
      class: 'lucide lucide-circle-slash-icon lucide-circle-slash',
    },
    [
      svgEl('circle', {
        cx: '12',
        cy: '12',
        r: '10',
      }),
      svgEl('line', {
        x1: '9',
        y1: '15',
        x2: '15',
        y2: '9',
      }),
    ],
  );
}

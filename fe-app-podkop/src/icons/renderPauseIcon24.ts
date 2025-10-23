import { svgEl } from '../helpers';

export function renderPauseIcon24() {
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
      class: 'lucide lucide-pause-icon lucide-pause',
    },
    [
      svgEl('rect', {
        x: '14',
        y: '3',
        width: '5',
        height: '18',
        rx: '1',
      }),
      svgEl('rect', {
        x: '5',
        y: '3',
        width: '5',
        height: '18',
        rx: '1',
      }),
    ],
  );
}

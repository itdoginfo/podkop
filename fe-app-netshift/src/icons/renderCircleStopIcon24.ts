import { svgEl } from '../helpers';

export function renderCircleStopIcon24() {
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
      class: 'lucide lucide-circle-stop-icon lucide-circle-stop',
    },
    [
      svgEl('circle', {
        cx: '12',
        cy: '12',
        r: '10',
      }),
      svgEl('rect', {
        x: '9',
        y: '9',
        width: '6',
        height: '6',
        rx: '1',
      }),
    ],
  );
}

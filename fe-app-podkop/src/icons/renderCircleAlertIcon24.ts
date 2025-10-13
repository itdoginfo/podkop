import { svgEl } from '../helpers';

export function renderCircleAlertIcon24() {
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
      class: 'lucide lucide-circle-alert-icon lucide-circle-alert',
    },
    [
      svgEl('circle', {
        cx: '12',
        cy: '12',
        r: '10',
      }),
      svgEl('line', {
        x1: '12',
        y1: '8',
        x2: '12',
        y2: '12',
      }),
      svgEl('line', {
        x1: '12',
        y1: '16',
        x2: '12.01',
        y2: '16',
      }),
    ],
  );
}

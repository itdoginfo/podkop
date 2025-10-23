import { svgEl } from '../helpers';

export function renderSquareChartGanttIcon24() {
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
      class: 'lucide lucide-square-chart-gantt-icon lucide-square-chart-gantt',
    },
    [
      svgEl('rect', {
        width: '18',
        height: '18',
        x: '3',
        y: '3',
        rx: '2',
      }),
      svgEl('path', { d: 'M9 8h7' }),
      svgEl('path', { d: 'M8 12h6' }),
      svgEl('path', { d: 'M11 16h5' }),
    ],
  );
}

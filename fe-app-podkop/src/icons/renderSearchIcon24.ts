import { svgEl } from '../helpers';

export function renderSearchIcon24() {
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
      class: 'lucide lucide-search-icon lucide-search',
    },
    [
      svgEl('path', { d: 'm21 21-4.34-4.34' }),
      svgEl('circle', { cx: '11', cy: '11', r: '8' }),
    ],
  );
}

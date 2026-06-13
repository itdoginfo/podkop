import { svgEl } from '../helpers';

export function renderCogIcon24() {
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
      class: 'lucide lucide-cog-icon lucide-cog',
    },
    [
      svgEl('path', { d: 'M11 10.27 7 3.34' }),
      svgEl('path', { d: 'm11 13.73-4 6.93' }),
      svgEl('path', { d: 'M12 22v-2' }),
      svgEl('path', { d: 'M12 2v2' }),
      svgEl('path', { d: 'M14 12h8' }),
      svgEl('path', { d: 'm17 20.66-1-1.73' }),
      svgEl('path', { d: 'm17 3.34-1 1.73' }),
      svgEl('path', { d: 'M2 12h2' }),
      svgEl('path', { d: 'm20.66 17-1.73-1' }),
      svgEl('path', { d: 'm20.66 7-1.73 1' }),
      svgEl('path', { d: 'm3.34 17 1.73-1' }),
      svgEl('path', { d: 'm3.34 7 1.73 1' }),
      svgEl('circle', { cx: '12', cy: '12', r: '2' }),
      svgEl('circle', { cx: '12', cy: '12', r: '8' }),
    ],
  );
}

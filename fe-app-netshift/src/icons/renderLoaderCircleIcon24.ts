import { svgEl } from '../helpers';

export function renderLoaderCircleIcon24() {
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
      class: 'lucide lucide-loader-circle rotate',
    },
    [
      svgEl('path', {
        d: 'M21 12a9 9 0 1 1-6.219-8.56',
      }),
      svgEl('animateTransform', {
        attributeName: 'transform',
        attributeType: 'XML',
        type: 'rotate',
        from: '0 12 12',
        to: '360 12 12',
        dur: '1s',
        repeatCount: 'indefinite',
      }),
    ],
  );
}

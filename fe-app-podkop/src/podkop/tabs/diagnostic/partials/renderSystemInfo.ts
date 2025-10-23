import { insertIf } from '../../../../helpers';

export interface IRenderSystemInfoRow {
  key: string;
  value: string;
  tag?: {
    label: string;
    kind: 'warning' | 'success';
  };
}

interface IRenderSystemInfoProps {
  items: Array<IRenderSystemInfoRow>;
}

export function renderSystemInfo({ items }: IRenderSystemInfoProps) {
  return E('div', { class: 'pdk_diagnostic-page__right-bar__system-info' }, [
    E(
      'b',
      { class: 'pdk_diagnostic-page__right-bar__system-info__title' },
      _('System information'),
    ),
    ...items.map((item) => {
      const tagClass = [
        'pdk_diagnostic-page__right-bar__system-info__row__tag',
        ...insertIf(item.tag?.kind === 'warning', [
          'pdk_diagnostic-page__right-bar__system-info__row__tag--warning',
        ]),
        ...insertIf(item.tag?.kind === 'success', [
          'pdk_diagnostic-page__right-bar__system-info__row__tag--success',
        ]),
      ]
        .filter(Boolean)
        .join(' ');

      return E(
        'div',
        { class: 'pdk_diagnostic-page__right-bar__system-info__row' },
        [
          E('b', {}, item.key),
          E('div', {}, [
            E('span', {}, item.value),
            E('span', { class: tagClass }, item?.tag?.label),
          ]),
        ],
      );
    }),
  ]);
}

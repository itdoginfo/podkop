interface IRenderSystemInfoProps {
  items: Array<{ key: string; value: string }>;
}

export function renderSystemInfo({ items }: IRenderSystemInfoProps) {
  return E('div', { class: 'pdk_diagnostic-page__right-bar__system-info' }, [
    E(
      'b',
      { class: 'pdk_diagnostic-page__right-bar__system-info__title' },
      'System information',
    ),
    ...items.map((item) =>
      E('div', { class: 'pdk_diagnostic-page__right-bar__system-info__row' }, [
        E('b', {}, item.key),
        E('div', {}, item.value),
      ]),
    ),
  ]);
}

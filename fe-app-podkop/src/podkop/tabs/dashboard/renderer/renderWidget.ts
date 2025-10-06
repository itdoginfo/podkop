interface IRenderWidgetParams {
  title: string;
  items: Array<{
    key: string;
    value: string;
    attributes?: {
      class?: string;
    };
  }>;
}

export function renderDashboardWidget({ title, items }: IRenderWidgetParams) {
  return E('div', { class: 'pdk_dashboard-page__widgets-section__item' }, [
    E(
      'b',
      { class: 'pdk_dashboard-page__widgets-section__item__title' },
      title,
    ),
    ...items.map((item) =>
      E(
        'div',
        {
          class: `pdk_dashboard-page__widgets-section__item__row ${item?.attributes?.class || ''}`,
        },
        [
          E(
            'span',
            { class: 'pdk_dashboard-page__widgets-section__item__row__key' },
            `${item.key}: `,
          ),
          E(
            'span',
            { class: 'pdk_dashboard-page__widgets-section__item__row__value' },
            item.value,
          ),
        ],
      ),
    ),
  ]);
}

interface IRenderWidgetParams {
  title: string;
  items: Array<{
    key: string;
    value: string;
  }>;
}

export function renderDashboardWidget({ title, items }: IRenderWidgetParams) {
  return E('div', { class: 'pdk_dashboard-page__widgets-section__item' }, [
    E('b', {}, title),
    ...items.map((item) =>
      E('div', {}, [E('span', {}, `${item.key}: `), E('span', {}, item.value)]),
    ),
  ]);
}

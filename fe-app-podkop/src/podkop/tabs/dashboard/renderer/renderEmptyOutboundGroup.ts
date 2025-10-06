export function renderEmptyOutboundGroup() {
  return E(
    'div',
    {
      class: 'pdk_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, 'Dashboard currently unavailable'),
  );
}

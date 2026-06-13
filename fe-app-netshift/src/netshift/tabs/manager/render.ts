export function render() {
  return E('div', { id: 'manager-status', class: 'pdk_manager-page' }, [
    E('div', {
      id: 'pdk_manager-components',
      class: 'pdk_manager-page__components',
    }),
  ]);
}

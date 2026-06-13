export function render() {
  return E('div', { id: 'diagnostic-status', class: 'pdk_diagnostic-page' }, [
    E('div', { class: 'pdk_diagnostic-page__left-bar' }, [
      E('div', { id: 'pdk_diagnostic-page-run-check' }),
      E('div', {
        class: 'pdk_diagnostic-page__checks',
        id: 'pdk_diagnostic-page-checks',
      }),
    ]),
    E('div', { class: 'pdk_diagnostic-page__right-bar' }, [
      E('div', { id: 'pdk_diagnostic-page-wiki' }),
      E('div', { id: 'pdk_diagnostic-page-actions' }),
      E('div', { id: 'pdk_diagnostic-page-system-info' }),
    ]),
  ]);
}

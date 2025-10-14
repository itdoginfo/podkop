export function renderAvailableActions() {
  return E('div', { class: 'pdk_diagnostic-page__right-bar__actions' }, [
    E('b', {}, 'Available actions'),
    E('button', { class: 'btn' }, 'Restart podkop'),
    E('button', { class: 'btn' }, 'Stop podkop'),
    E('button', { class: 'btn' }, 'Disable podkop'),
    E('button', { class: 'btn' }, 'Get global check'),
    E('button', { class: 'btn' }, 'View logs'),
    E('button', { class: 'btn' }, 'Show sing-box config'),
  ]);
}

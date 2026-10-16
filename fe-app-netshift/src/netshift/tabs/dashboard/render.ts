import { renderSections, renderWidget } from './partials';

// The tiles with traffic and system numbers can be switched off in the settings
// (dashboard_widgets); they are shown unless the option says 0.
function widgetsAreShown(): boolean {
  try {
    return uci.get('netshift', 'settings', 'dashboard_widgets') !== '0';
  } catch {
    return true;
  }
}

export function render() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'pdk_dashboard-page',
    },
    [
      // A newer version is available (filled by the controller)
      E('div', { id: 'dashboard-update-notice' }),
      // The servers the pin guard gave up (filled by the controller)
      E('div', { id: 'dashboard-pin-guard' }),
      // Widgets section
      E(
        'div',
        {
          class: 'pdk_dashboard-page__widgets-section',
          ...(widgetsAreShown() ? {} : { style: 'display: none' }),
        },
        [
          E(
            'div',
            { id: 'dashboard-widget-traffic' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
          E(
            'div',
            { id: 'dashboard-widget-traffic-total' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
          E(
            'div',
            { id: 'dashboard-widget-system-info' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
          E(
            'div',
            { id: 'dashboard-widget-service-info' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
        ],
      ),
      // Subscription refresh toolbar (hidden without subscription sections)
      E('div', { id: 'dashboard-sections-toolbar' }),
      // All outbounds
      E(
        'div',
        { id: 'dashboard-sections-grid' },
        renderSections({
          loading: true,
          failed: false,
          section: {
            code: '',
            displayName: '',
            outbounds: [],
            withTagSelect: false,
          },
          onTestLatency: () => {},
          onChooseOutbound: () => {},
          latencyFetching: false,
          pendingOutbounds: [],
          viewMode: 'list',
          sortByPing: false,
          onToggleViewMode: () => {},
          onToggleSortByPing: () => {},
          subscriptionInfo: [],
        }),
      ),
    ],
  );
}

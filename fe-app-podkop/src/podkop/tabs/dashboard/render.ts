import { renderSections, renderWidget } from './partials';

export function render() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'pdk_dashboard-page',
    },
    [
      // Widgets section
      E('div', { class: 'pdk_dashboard-page__widgets-section' }, [
        E(
          'div',
          { id: 'dashboard-widget-traffic' },
          renderWidget({ loading: true, failed: false, title: '', items: [] }),
        ),
        E(
          'div',
          { id: 'dashboard-widget-traffic-total' },
          renderWidget({ loading: true, failed: false, title: '', items: [] }),
        ),
        E(
          'div',
          { id: 'dashboard-widget-system-info' },
          renderWidget({ loading: true, failed: false, title: '', items: [] }),
        ),
        E(
          'div',
          { id: 'dashboard-widget-service-info' },
          renderWidget({ loading: true, failed: false, title: '', items: [] }),
        ),
      ]),
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
        }),
      ),
    ],
  );
}

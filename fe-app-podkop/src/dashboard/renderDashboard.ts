export function renderDashboard() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'pdk_dashboard-page',
    },
    [
      // Title section
      E('div', { class: 'pdk_dashboard-page__title-section' }, [
        E(
          'h3',
          { class: 'pdk_dashboard-page__title-section__title' },
          'Overall (alpha)',
        ),
        E('label', {}, [
          E('input', { type: 'checkbox', disabled: true, checked: true }),
          ' Runtime',
        ]),
      ]),
      // Widgets section
      E('div', { class: 'pdk_dashboard-page__widgets-section' }, [
        E('div', { id: 'dashboard-widget-traffic' }, [
          E(
            'div',
            {
              id: '',
              style: 'height: 78px',
              class: 'pdk_dashboard-page__widgets-section__item skeleton',
            },
            '',
          ),
        ]),
        E('div', { id: 'dashboard-widget-traffic-total' }, [
          E(
            'div',
            {
              id: '',
              style: 'height: 78px',
              class: 'pdk_dashboard-page__widgets-section__item skeleton',
            },
            '',
          ),
        ]),
        E('div', { id: 'dashboard-widget-system-info' }, [
          E(
            'div',
            {
              id: '',
              style: 'height: 78px',
              class: 'pdk_dashboard-page__widgets-section__item skeleton',
            },
            '',
          ),
        ]),
        E('div', { id: 'dashboard-widget-service-info' }, [
          E(
            'div',
            {
              id: '',
              style: 'height: 78px',
              class: 'pdk_dashboard-page__widgets-section__item skeleton',
            },
            '',
          ),
        ]),
      ]),
      // All outbounds
      E('div', { id: 'dashboard-sections-grid' }, [
        E('div', {
          id: 'dashboard-sections-grid-skeleton',
          class: 'pdk_dashboard-page__outbound-section skeleton',
          style: 'height: 127px',
        }),
      ]),
    ],
  );
}

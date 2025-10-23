import { Podkop } from '../../../types';

interface IRenderSectionsProps {
  loading: boolean;
  failed: boolean;
  section: Podkop.OutboundGroup;
  onTestLatency: (tag: string) => void;
  onChooseOutbound: (selector: string, tag: string) => void;
  latencyFetching: boolean;
}

function renderFailedState() {
  return E(
    'div',
    {
      class: 'pdk_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, [E('span', {}, _('Dashboard currently unavailable'))]),
  );
}

function renderLoadingState() {
  return E('div', {
    id: 'dashboard-sections-grid-skeleton',
    class: 'pdk_dashboard-page__outbound-section skeleton',
    style: 'height: 127px',
  });
}

export function renderDefaultState({
  section,
  onChooseOutbound,
  onTestLatency,
  latencyFetching,
}: IRenderSectionsProps) {
  function testLatency() {
    if (section.withTagSelect) {
      return onTestLatency(section.code);
    }

    if (section.outbounds.length) {
      return onTestLatency(section.outbounds[0].code);
    }
  }

  function renderOutbound(outbound: Podkop.Outbound) {
    function getLatencyClass() {
      if (!outbound.latency) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--empty';
      }

      if (outbound.latency < 800) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--green';
      }

      if (outbound.latency < 1500) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--yellow';
      }

      return 'pdk_dashboard-page__outbound-grid__item__latency--red';
    }

    return E(
      'div',
      {
        class: `pdk_dashboard-page__outbound-grid__item ${outbound.selected ? 'pdk_dashboard-page__outbound-grid__item--active' : ''} ${section.withTagSelect ? 'pdk_dashboard-page__outbound-grid__item--selectable' : ''}`,
        click: () =>
          section.withTagSelect &&
          onChooseOutbound(section.code, outbound.code),
      },
      [
        E('b', {}, outbound.displayName),
        E('div', { class: 'pdk_dashboard-page__outbound-grid__item__footer' }, [
          E(
            'div',
            { class: 'pdk_dashboard-page__outbound-grid__item__type' },
            outbound.type,
          ),
          E(
            'div',
            { class: getLatencyClass() },
            outbound.latency ? `${outbound.latency}ms` : 'N/A',
          ),
        ]),
      ],
    );
  }

  return E('div', { class: 'pdk_dashboard-page__outbound-section' }, [
    // Title with test latency
    E('div', { class: 'pdk_dashboard-page__outbound-section__title-section' }, [
      E(
        'div',
        {
          class: 'pdk_dashboard-page__outbound-section__title-section__title',
        },
        section.displayName,
      ),
      latencyFetching
        ? E('div', { class: 'skeleton', style: 'width: 99px; height: 28px' })
        : E(
            'button',
            {
              class: 'btn dashboard-sections-grid-item-test-latency',
              click: () => testLatency(),
            },
            _('Test latency'),
          ),
    ]),
    E(
      'div',
      { class: 'pdk_dashboard-page__outbound-grid' },
      section.outbounds.map((outbound) => renderOutbound(outbound)),
    ),
  ]);
}

export function renderSections(props: IRenderSectionsProps) {
  if (props.failed) {
    return renderFailedState();
  }

  if (props.loading) {
    return renderLoadingState();
  }

  return renderDefaultState(props);
}

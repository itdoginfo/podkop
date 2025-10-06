import { Podkop } from '../../podkop/types';

export function renderOutboundGroup({
  outbounds,
  displayName,
}: Podkop.OutboundGroup) {
  function renderOutbound(outbound: Podkop.Outbound) {
    function getLatencyClass() {

      if (!outbound.latency) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--empty';
      }

      if (outbound.latency < 200) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--green';
      }

      if (outbound.latency < 400) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--yellow';
      }

      return 'pdk_dashboard-page__outbound-grid__item__latency--red';
    }

    return E(
      'div',
      {
        class: `pdk_dashboard-page__outbound-grid__item ${outbound.selected ? 'pdk_dashboard-page__outbound-grid__item--active' : ''}`,
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
        displayName,
      ),
      E('button', { class: 'btn' }, 'Test latency'),
    ]),
    E(
      'div',
      { class: 'pdk_dashboard-page__outbound-grid' },
      outbounds.map((outbound) => renderOutbound(outbound)),
    ),
  ]);
}

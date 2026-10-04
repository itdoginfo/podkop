import { renderButton } from '../../../../partials';
import { NetShift } from '../../../types';
import { SKELETON_SHIMMER_DURATION } from '../../../../constants';
import type { DashboardViewMode } from '../../../../helpers/dashboardView';
import { sortOutboundsByLatency } from '../sortOutbounds';

// The color class of a delay: the same thresholds for tiles and list rows.
function getLatencyClassName(latency: number) {
  if (!latency) {
    return 'pdk_dashboard-page__outbound-grid__item__latency--empty';
  }

  if (latency < 800) {
    return 'pdk_dashboard-page__outbound-grid__item__latency--green';
  }

  if (latency < 1500) {
    return 'pdk_dashboard-page__outbound-grid__item__latency--yellow';
  }

  return 'pdk_dashboard-page__outbound-grid__item__latency--red';
}

interface IRenderSectionsProps {
  loading: boolean;
  failed: boolean;
  section: NetShift.OutboundGroup;
  onTestLatency: () => void;
  onChooseOutbound: (selector: string, tag: string) => void;
  latencyFetching: boolean;
  // Outbound codes whose latency is being measured right now.
  pendingOutbounds: string[];
  viewMode: DashboardViewMode;
  sortByPing: boolean;
  onToggleViewMode: () => void;
  onToggleSortByPing: () => void;
}

function renderFailedState() {
  return E(
    'div',
    {
      class: 'card pdk_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, [E('span', {}, _('Dashboard currently unavailable'))]),
  );
}

function renderLoadingState() {
  return E('div', {
    id: 'dashboard-sections-grid-skeleton',
    class: 'card pdk_dashboard-page__outbound-section skeleton',
    style: 'height: 127px',
  });
}

// The widget is rebuilt on every latency result. Starting each new skeleton
// at the shared shimmer phase keeps the animation running instead of
// restarting it.
function renderSkeleton(style: string) {
  const phase = Math.round(performance.now() % SKELETON_SHIMMER_DURATION);

  return E('div', {
    class: 'skeleton',
    style: `${style}; --skeleton-phase: -${phase}ms`,
  });
}

export function renderDefaultState({
  section,
  onChooseOutbound,
  onTestLatency,
  latencyFetching,
  pendingOutbounds,
  viewMode,
  sortByPing,
  onToggleViewMode,
  onToggleSortByPing,
}: IRenderSectionsProps) {
  function renderOutbound(outbound: NetShift.Outbound) {
    const getLatencyClass = () => getLatencyClassName(outbound.latency);

    return E(
      'div',
      {
        class: `card pdk_dashboard-page__outbound-grid__item ${outbound.selected ? 'pdk_dashboard-page__outbound-grid__item--active' : ''} ${section.withTagSelect ? 'pdk_dashboard-page__outbound-grid__item--selectable' : ''}`,
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
          pendingOutbounds.includes(outbound.code)
            ? renderSkeleton('width: 44px; height: 16px')
            : E(
                'div',
                { class: getLatencyClass() },
                outbound.latency ? `${outbound.latency}ms` : 'N/A',
              ),
        ]),
      ],
    );
  }

  function renderRow(outbound: NetShift.Outbound) {
    return E(
      'div',
      {
        class: `pdk_dashboard-page__outbound-row ${outbound.selected ? 'pdk_dashboard-page__outbound-row--active' : ''} ${section.withTagSelect ? 'pdk_dashboard-page__outbound-row--selectable' : ''}`,
        click: () =>
          section.withTagSelect &&
          onChooseOutbound(section.code, outbound.code),
      },
      [
        E(
          'b',
          { class: 'pdk_dashboard-page__outbound-row__name' },
          outbound.displayName,
        ),
        E(
          'span',
          { class: 'pdk_dashboard-page__outbound-row__type' },
          outbound.type,
        ),
        pendingOutbounds.includes(outbound.code)
          ? renderSkeleton('width: 44px; height: 16px; margin-left: auto')
          : E(
              'span',
              {
                class: `pdk_dashboard-page__outbound-row__latency ${getLatencyClassName(outbound.latency)}`,
              },
              outbound.latency ? `${outbound.latency}ms` : 'N/A',
            ),
        outbound.selected
          ? E(
              'span',
              { class: 'pdk_dashboard-page__outbound-row__badge' },
              _('Active'),
            )
          : E('span', {
              class: 'pdk_dashboard-page__outbound-row__badge-space',
            }),
      ],
    );
  }

  function renderOutbounds(outbounds: NetShift.Outbound[], key: string) {
    const items = sortByPing ? sortOutboundsByLatency(outbounds) : outbounds;

    if (viewMode === 'tiles') {
      return E(
        'div',
        { class: 'pdk_dashboard-page__outbound-grid' },
        items.map((outbound) => renderOutbound(outbound)),
      );
    }

    const list = E(
      'div',
      { class: 'pdk_dashboard-page__outbound-list' },
      items.map((outbound) => renderRow(outbound)),
    );
    list.dataset.listKey = key;

    return list;
  }

  return E('div', { class: 'card pdk_dashboard-page__outbound-section' }, [
    // Title with test latency
    E('div', { class: 'pdk_dashboard-page__outbound-section__title-section' }, [
      E(
        'div',
        {
          class: 'pdk_dashboard-page__outbound-section__title-section__title',
        },
        section.displayName,
      ),
      E('div', { class: 'pdk_dashboard-page__outbound-section__controls' }, [
        renderButton({
          text: viewMode === 'list' ? _('Tiles') : _('List'),
          onClick: () => onToggleViewMode(),
        }),
        renderButton({
          text: _('Sort by ping'),
          onClick: () => onToggleSortByPing(),
          classNames: sortByPing ? ['pdk_dashboard-page__control--on'] : [],
        }),
        latencyFetching
          ? renderSkeleton('width: 99px; height: 28px')
          : renderButton({
              text: _('Test latency'),
              onClick: () => onTestLatency(),
              classNames: ['dashboard-sections-grid-item-test-latency'],
            }),
      ]),
    ]),
    renderOutbounds(section.outbounds, section.code),
    ...(section.subgroups ?? []).map((subgroup) =>
      E('div', { class: 'pdk_dashboard-page__outbound-subgroup' }, [
        E(
          'div',
          { class: 'pdk_dashboard-page__outbound-subgroup__title' },
          subgroup.displayName,
        ),
        renderOutbounds(subgroup.outbounds, `${section.code}:${subgroup.code}`),
      ]),
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

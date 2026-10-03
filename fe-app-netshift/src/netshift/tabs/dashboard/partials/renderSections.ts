import { renderButton } from '../../../../partials';
import { NetShift } from '../../../types';
import { SKELETON_SHIMMER_DURATION } from '../../../../constants';

// A specific subscription feed to refresh: the dashboard feed-block name (the
// backend resolves it to its URL) or the raw URL for a single-feed section.
// `key` is the section/subgroup code used to show the button's loading state.
export interface IRefreshFeedTarget {
  name?: string;
  url?: string;
  key: string;
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
  // Subscription sections only: refresh one feed (subgroup header) or the whole
  // section (single-feed section header). Absent outside the dashboard.
  onRefreshFeed?: (
    section: NetShift.OutboundGroup,
    feed: IRefreshFeedTarget,
  ) => void;
  refreshingFeedKeys?: string[];
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
  onRefreshFeed,
  refreshingFeedKeys,
}: IRenderSectionsProps) {
  // Subscription refresh is only offered when the dashboard wired the handler
  // (the loading/failed placeholders render without one).
  const canRefresh = Boolean(section.isSubscription && onRefreshFeed);
  const hasSubgroups = (section.subgroups?.length ?? 0) > 0;

  function renderRefreshButton(feed: IRefreshFeedTarget) {
    return renderButton({
      text: _('Refresh subscription'),
      loading: refreshingFeedKeys?.includes(feed.key),
      onClick: () => onRefreshFeed?.(section, feed),
      classNames: ['dashboard-sections-grid-item-refresh-subscription'],
    });
  }

  function renderOutbound(outbound: NetShift.Outbound) {
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
      E(
        'div',
        {
          class: 'pdk_dashboard-page__outbound-section__title-section__actions',
        },
        [
          // A multi-feed section offers one refresh per feed block below; a
          // single-feed section gets its only refresh button here.
          ...(canRefresh &&
          !hasSubgroups &&
          (section.subscriptionUrls?.length ?? 0) > 0
            ? [
                renderRefreshButton({
                  url: section.subscriptionUrls?.[0],
                  key: section.code,
                }),
              ]
            : []),
          latencyFetching
            ? renderSkeleton('width: 99px; height: 28px')
            : renderButton({
                text: _('Test latency'),
                onClick: () => onTestLatency(),
                classNames: ['dashboard-sections-grid-item-test-latency'],
              }),
        ],
      ),
    ]),
    E(
      'div',
      { class: 'pdk_dashboard-page__outbound-grid' },
      section.outbounds.map((outbound) => renderOutbound(outbound)),
    ),
    ...(section.subgroups ?? []).map((subgroup) =>
      E('div', { class: 'pdk_dashboard-page__outbound-subgroup' }, [
        E('div', { class: 'pdk_dashboard-page__outbound-subgroup__header' }, [
          E(
            'div',
            { class: 'pdk_dashboard-page__outbound-subgroup__title' },
            subgroup.displayName,
          ),
          ...(canRefresh
            ? [
                renderRefreshButton({
                  name: subgroup.displayName,
                  key: subgroup.code,
                }),
              ]
            : []),
        ]),
        E(
          'div',
          { class: 'pdk_dashboard-page__outbound-grid' },
          subgroup.outbounds.map((outbound) => renderOutbound(outbound)),
        ),
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

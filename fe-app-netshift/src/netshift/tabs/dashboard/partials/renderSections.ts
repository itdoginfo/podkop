import { renderButton } from '../../../../partials';
import { NetShift } from '../../../types';
import { SKELETON_SHIMMER_DURATION } from '../../../../constants';
import type { DashboardViewMode } from '../../../../helpers/dashboardView';
import { sortOutboundsByLatency } from '../sortOutbounds';
import {
  describeSubscriptionInfo,
  type SubscriptionInfo,
} from '../../../../helpers/subscriptionInfo';
import { prettyBytes } from '../../../../helpers/prettyBytes';

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

// What a refresh button updates: one feed block (`feed` is the block's
// sing-box group tag, which the backend resolves to the feed URL) or, without
// `feed`, every feed of the section. `key` is the section/subgroup code that
// marks the button as the one in progress.
export interface IRefreshFeedTarget {
  feed?: string;
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
  viewMode: DashboardViewMode;
  sortByPing: boolean;
  onToggleViewMode: () => void;
  onToggleSortByPing: () => void;
  // Subscription sections only: refresh one feed (subgroup header) or the whole
  // section (header of a section without feed blocks). Absent outside the
  // dashboard.
  onRefreshFeed?: (
    section: NetShift.OutboundGroup,
    feed: IRefreshFeedTarget,
  ) => void;
  // The refresh in flight ('all', or the key of the button that started it):
  // that button spins, every other refresh button is disabled.
  subscriptionRefreshKey?: string | null;
  // Traffic and expiry the panels of this section's subscriptions report.
  subscriptionInfo: SubscriptionInfo[];
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

// One line per feed: traffic used of the quota, and when the account ends.
function renderSubscriptionInfo(infos: SubscriptionInfo[]) {
  const now = Math.floor(Date.now() / 1000);

  return E(
    'div',
    { class: 'pdk_dashboard-page__subscription-info' },
    infos.map((info) => {
      const line = describeSubscriptionInfo(info, now);
      const parts: string[] = [];

      if (line.used !== null) {
        parts.push(
          line.total !== null
            ? `${_('Traffic')}: ${prettyBytes(line.used)} / ${prettyBytes(line.total)}`
            : `${_('Traffic')}: ${prettyBytes(line.used)}`,
        );
      }

      if (line.expireDate !== null && line.daysLeft !== null) {
        parts.push(
          line.daysLeft < 0
            ? `${_('Expired')}: ${line.expireDate}`
            : `${_('Expires')}: ${line.expireDate} (${line.daysLeft} ${_('days left')})`,
        );
      }

      const name = infos.length > 1 && line.title ? `${line.title}: ` : '';
      const text = E(
        'span',
        {
          class: `pdk_dashboard-page__subscription-info__text${line.exhausted ? ' pdk_dashboard-page__subscription-info__text--exhausted' : ''}`,
        },
        name + parts.join(' · '),
      );

      return E('div', { class: 'pdk_dashboard-page__subscription-info__row' }, [
        text,
        ...(line.percent !== null
          ? [
              E(
                'div',
                { class: 'pdk_dashboard-page__subscription-info__bar' },
                [
                  E('div', {
                    class: `pdk_dashboard-page__subscription-info__bar__fill${line.percent >= 90 ? ' pdk_dashboard-page__subscription-info__bar__fill--high' : ''}`,
                    style: `width: ${line.percent}%`,
                  }),
                ],
              ),
            ]
          : []),
      ]);
    }),
  );
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
  onRefreshFeed,
  subscriptionRefreshKey,
  subscriptionInfo,
}: IRenderSectionsProps) {
  // Subscription refresh is only offered when the dashboard wired the handler
  // (the loading/failed placeholders render without one).
  const canRefresh = Boolean(section.isSubscription && onRefreshFeed);
  const hasSubgroups = (section.subgroups?.length ?? 0) > 0;

  function renderRefreshButton(feed: IRefreshFeedTarget) {
    return renderButton({
      text: _('Refresh subscription'),
      loading: subscriptionRefreshKey === feed.key,
      disabled: Boolean(subscriptionRefreshKey),
      onClick: () => onRefreshFeed?.(section, feed),
      classNames: ['dashboard-sections-grid-item-refresh-subscription'],
    });
  }

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
        // A section split into feed blocks offers one refresh per block below.
        // Any other subscription section (one feed, country/prefix groups, or
        // several feeds of which only one gave nodes) gets a single button
        // here that refreshes every feed of the section.
        ...(canRefresh && !hasSubgroups
          ? [renderRefreshButton({ key: section.code })]
          : []),
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
    ...(subscriptionInfo.length > 0
      ? [renderSubscriptionInfo(subscriptionInfo)]
      : []),
    renderOutbounds(section.outbounds, section.code),
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
                  feed: subgroup.code,
                  key: subgroup.code,
                }),
              ]
            : []),
        ]),
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

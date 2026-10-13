import {
  getClashWsUrl,
  onMount,
  preserveScrollForPage,
} from '../../../helpers';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { showToast } from '../../../helpers/showToast';
import {
  parseSubscriptionInfo,
  subscriptionInfoOf,
} from '../../../helpers/subscriptionInfo';
import {
  loadDashboardViewPrefs,
  saveDashboardViewPrefs,
} from '../../../helpers/dashboardView';
import { CustomNetShiftMethods, NetShiftShellMethods } from '../../methods';
import {
  getOutdatedComponents,
  parseUpdateNotice,
  shouldRefreshUpdateNotice,
  type UpdateNotice,
} from '../../../helpers/updateNotice';
import {
  parsePinGuardEvents,
  recentPinGuardEvents,
} from '../../../helpers/pinGuardEvents';
import { logger, socket, store, StoreType } from '../../services';
import {
  IRefreshFeedTarget,
  renderSections,
  renderSectionsToolbar,
  renderWidget,
} from './partials';
import { fetchServicesInfo } from '../../fetchers';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { NetShift } from '../../types';
import {
  getLatencyTargets,
  runWithConcurrency,
  setOutboundLatency,
} from './latency';

// Latency probes in flight. Each one is a netshift CLI run on the router: on
// a dual-core MT7981 8 of them measured 144 servers in 37 s.
const LATENCY_PROBE_CONCURRENCY = 8;

// Fetchers

async function fetchDashboardSections() {
  const prev = store.get().sectionsWidget;

  store.set({
    sectionsWidget: {
      ...prev,
      failed: false,
    },
  });

  const { data, success } = await CustomNetShiftMethods.getDashboardSections();

  if (!success) {
    logger.error('[DASHBOARD]', 'fetchDashboardSections: failed to fetch');
  }

  // Keep the latency-test state: a refresh may land while a test runs.
  store.set({
    sectionsWidget: {
      ...store.get().sectionsWidget,
      loading: false,
      failed: !success,
      data,
    },
  });

  void fetchSubscriptionInfo();
}

// Traffic and expiry the subscription panels report. Optional: an old backend
// or a panel without the header just leaves the line out.
async function fetchSubscriptionInfo() {
  try {
    const response = await NetShiftShellMethods.getSubscriptionInfo();
    const subscriptionInfo = response.success
      ? parseSubscriptionInfo(response.data)
      : {};

    store.set({
      sectionsWidget: {
        ...store.get().sectionsWidget,
        subscriptionInfo,
      },
    });
  } catch (e) {
    logger.error('[DASHBOARD]', 'fetchSubscriptionInfo: failed', e);
  }
}

async function connectToClashSockets() {
  const clashApiSecret = await getClashApiSecret();

  socket.subscribe(
    `${getClashWsUrl()}/traffic?token=${clashApiSecret}`,
    (msg) => {
      const parsedMsg = JSON.parse(msg);

      store.set({
        bandwidthWidget: {
          loading: false,
          failed: false,
          data: { up: parsedMsg.up, down: parsedMsg.down },
        },
      });
    },
    (_err) => {
      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - traffic: failed to connect to',
        getClashWsUrl(),
      );
      store.set({
        bandwidthWidget: {
          loading: false,
          failed: true,
          data: { up: 0, down: 0 },
        },
      });
    },
  );

  socket.subscribe(
    `${getClashWsUrl()}/connections?token=${clashApiSecret}`,
    (msg) => {
      const parsedMsg = JSON.parse(msg);

      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: false,
          data: {
            downloadTotal: parsedMsg.downloadTotal,
            uploadTotal: parsedMsg.uploadTotal,
          },
        },
        systemInfoWidget: {
          loading: false,
          failed: false,
          data: {
            connections: parsedMsg.connections?.length,
            memory: parsedMsg.memory,
          },
        },
      });
    },
    (_err) => {
      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - connections: failed to connect to',
        getClashWsUrl(),
      );
      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: true,
          data: { downloadTotal: 0, uploadTotal: 0 },
        },
        systemInfoWidget: {
          loading: false,
          failed: true,
          data: {
            connections: 0,
            memory: 0,
          },
        },
      });
    },
  );
}

// Handlers

async function handleChooseOutbound(selector: string, tag: string) {
  await NetShiftShellMethods.setClashApiGroupProxy(selector, tag);
  await fetchDashboardSections();
}

function handleToggleViewMode() {
  const widget = store.get().sectionsWidget;
  const viewMode = widget.viewMode === 'list' ? 'tiles' : 'list';

  saveDashboardViewPrefs({ viewMode, sortByPing: widget.sortByPing });
  store.set({ sectionsWidget: { ...widget, viewMode } });
}

function handleToggleSortByPing() {
  const widget = store.get().sectionsWidget;
  const sortByPing = !widget.sortByPing;

  saveDashboardViewPrefs({ viewMode: widget.viewMode, sortByPing });
  store.set({ sectionsWidget: { ...widget, sortByPing } });
}

function updateSectionsWidget(
  update: (
    widget: StoreType['sectionsWidget'],
  ) => Partial<StoreType['sectionsWidget']>,
) {
  const widget = store.get().sectionsWidget;

  store.set({ sectionsWidget: { ...widget, ...update(widget) } });
}

// Each server is probed by its own request, so its card updates as soon as
// its answer arrives instead of after the slowest one.
async function handleTestSectionLatency(section: NetShift.OutboundGroup) {
  const { probe, groups } = getLatencyTargets(section);

  updateSectionsWidget((widget) => ({
    latencyTestingSections: [...widget.latencyTestingSections, section.code],
    latencyPendingOutbounds: [
      ...widget.latencyPendingOutbounds,
      ...probe,
      ...groups,
    ],
  }));

  try {
    await runWithConcurrency(probe, LATENCY_PROBE_CONCURRENCY, async (code) => {
      // A failed or timed-out probe shows N/A, like sing-box, which drops
      // the server's history on a failed test.
      const latency = await NetShiftShellMethods.getClashApiProxyLatency(code)
        .then((response) => (response.success && response.data?.delay) || 0)
        .catch(() => 0);

      updateSectionsWidget((widget) => ({
        data: setOutboundLatency(widget.data, code, latency),
        latencyPendingOutbounds: widget.latencyPendingOutbounds.filter(
          (item) => item !== code,
        ),
      }));
    });

    // "Fastest" cards and the selection come from Clash API.
    await fetchDashboardSections();
  } finally {
    // Even if something above throws, the button and the cards must not
    // stay skeletons forever.
    updateSectionsWidget((widget) => ({
      latencyTestingSections: widget.latencyTestingSections.filter(
        (item) => item !== section.code,
      ),
      latencyPendingOutbounds: widget.latencyPendingOutbounds.filter(
        (item) => !probe.includes(item) && !groups.includes(item),
      ),
    }));
  }
}

// The key of the "refresh all subscriptions" run in subscriptionRefreshKey.
const REFRESH_ALL_KEY = 'all';

// Runs one subscription refresh at a time. Two backend updates side by side
// race on the feed cache and on the sing-box reload, so while one is in flight
// every refresh button is disabled and a second call is dropped here.
// The marker is cleared whatever happens: a failed sections refetch must not
// leave the buttons spinning until the tab is reopened.
async function runSubscriptionRefresh(
  key: string,
  run: () => Promise<void>,
): Promise<void> {
  if (store.get().sectionsWidget.subscriptionRefreshKey) {
    return;
  }

  updateSectionsWidget(() => ({ subscriptionRefreshKey: key }));

  try {
    await run();
    await fetchDashboardSections();
  } catch (e) {
    logger.error('[DASHBOARD]', 'runSubscriptionRefresh - e', e);
  } finally {
    updateSectionsWidget(() => ({ subscriptionRefreshKey: null }));
  }
}

// Refreshes one subscription feed block, or every feed of a section when the
// button sits on the section header. The backend re-downloads the feed(s) and
// applies the change; the button spins until the async job reports back.
async function handleRefreshFeed(
  section: NetShift.OutboundGroup,
  feed: IRefreshFeedTarget,
) {
  await runSubscriptionRefresh(feed.key, async () => {
    try {
      const result = await NetShiftShellMethods.refreshSubscriptionFeed(
        section.sectionName ?? section.code,
        feed.feed,
      );

      if (result.success) {
        showToast(_('Subscription updated'), 'success');
      } else {
        logger.error('[DASHBOARD]', 'handleRefreshFeed - result', result);
        showToast(
          result.message || _('Failed to update subscription'),
          'error',
        );
      }
    } catch (e) {
      logger.error('[DASHBOARD]', 'handleRefreshFeed - e', e);
      showToast(_('Failed to update subscription'), 'error');
    }
  });
}

async function handleRefreshAllSubscriptions() {
  await runSubscriptionRefresh(REFRESH_ALL_KEY, async () => {
    showToast(_('Updating all subscriptions… this may take a minute'), 'info');

    try {
      const result = await NetShiftShellMethods.refreshAllSubscriptions();

      if (result.success) {
        showToast(_('All subscriptions updated'), 'success');
      } else {
        logger.error(
          '[DASHBOARD]',
          'handleRefreshAllSubscriptions - result',
          result,
        );
        showToast(
          result.message || _('Failed to update subscriptions'),
          'error',
        );
      }
    } catch (e) {
      logger.error('[DASHBOARD]', 'handleRefreshAllSubscriptions - e', e);
      showToast(_('Failed to update subscriptions'), 'error');
    }
  });
}

// Renderer

async function renderSectionsWidget() {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');
  const toolbarContainer = document.getElementById(
    'dashboard-sections-toolbar',
  );

  if (sectionsWidget.loading || sectionsWidget.failed) {
    toolbarContainer?.replaceChildren();

    const renderedWidget = renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
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
      viewMode: sectionsWidget.viewMode,
      sortByPing: sectionsWidget.sortByPing,
      onToggleViewMode: () => {},
      onToggleSortByPing: () => {},
      subscriptionInfo: [],
    });

    return preserveScrollForPage(() => {
      container!.replaceChildren(renderedWidget);
    });
  }

  toolbarContainer?.replaceChildren(
    renderSectionsToolbar({
      visible: sectionsWidget.data.some((section) => section.isSubscription),
      refreshing: sectionsWidget.subscriptionRefreshKey === REFRESH_ALL_KEY,
      disabled: Boolean(sectionsWidget.subscriptionRefreshKey),
      onRefreshAll: handleRefreshAllSubscriptions,
    }),
  );

  const renderedWidgets = sectionsWidget.data.map((section) =>
    renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section,
      latencyFetching: sectionsWidget.latencyTestingSections.includes(
        section.code,
      ),
      pendingOutbounds: sectionsWidget.latencyPendingOutbounds,
      onTestLatency: () => handleTestSectionLatency(section),
      onChooseOutbound: (selector, tag) => {
        handleChooseOutbound(selector, tag);
      },
      viewMode: sectionsWidget.viewMode,
      sortByPing: sectionsWidget.sortByPing,
      onToggleViewMode: handleToggleViewMode,
      onToggleSortByPing: handleToggleSortByPing,
      onRefreshFeed: handleRefreshFeed,
      subscriptionRefreshKey: sectionsWidget.subscriptionRefreshKey,
      subscriptionInfo: subscriptionInfoOf(
        sectionsWidget.subscriptionInfo,
        section,
      ),
    }),
  );

  // The lists scroll on their own and are rebuilt on every latency result:
  // keep the position of each one.
  const listScroll = new Map<string, number>();
  container!
    .querySelectorAll<HTMLElement>('[data-list-key]')
    .forEach((list) =>
      listScroll.set(list.dataset.listKey ?? '', list.scrollTop),
    );

  return preserveScrollForPage(() => {
    container!.replaceChildren(...renderedWidgets);
    container!
      .querySelectorAll<HTMLElement>('[data-list-key]')
      .forEach((list) => {
        list.scrollTop = listScroll.get(list.dataset.listKey ?? '') ?? 0;
      });
  });
}

async function renderBandwidthWidget() {
  logger.debug('[DASHBOARD]', 'renderBandwidthWidget');
  const traffic = store.get().bandwidthWidget;

  const container = document.getElementById('dashboard-widget-traffic');

  if (traffic.loading || traffic.failed) {
    const renderedWidget = renderWidget({
      loading: traffic.loading,
      failed: traffic.failed,
      title: '',
      items: [],
    });

    return container!.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: traffic.loading,
    failed: traffic.failed,
    title: _('Traffic'),
    items: [
      { key: _('Uplink'), value: `${prettyBytes(traffic.data.up)}/s` },
      { key: _('Downlink'), value: `${prettyBytes(traffic.data.down)}/s` },
    ],
  });

  container!.replaceChildren(renderedWidget);
}

async function renderTrafficTotalWidget() {
  logger.debug('[DASHBOARD]', 'renderTrafficTotalWidget');
  const trafficTotalWidget = store.get().trafficTotalWidget;

  const container = document.getElementById('dashboard-widget-traffic-total');

  if (trafficTotalWidget.loading || trafficTotalWidget.failed) {
    const renderedWidget = renderWidget({
      loading: trafficTotalWidget.loading,
      failed: trafficTotalWidget.failed,
      title: '',
      items: [],
    });

    return container!.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: trafficTotalWidget.loading,
    failed: trafficTotalWidget.failed,
    title: _('Traffic Total'),
    items: [
      {
        key: _('Uplink'),
        value: String(prettyBytes(trafficTotalWidget.data.uploadTotal)),
      },
      {
        key: _('Downlink'),
        value: String(prettyBytes(trafficTotalWidget.data.downloadTotal)),
      },
    ],
  });

  container!.replaceChildren(renderedWidget);
}

async function renderSystemInfoWidget() {
  logger.debug('[DASHBOARD]', 'renderSystemInfoWidget');
  const systemInfoWidget = store.get().systemInfoWidget;

  const container = document.getElementById('dashboard-widget-system-info');

  if (systemInfoWidget.loading || systemInfoWidget.failed) {
    const renderedWidget = renderWidget({
      loading: systemInfoWidget.loading,
      failed: systemInfoWidget.failed,
      title: '',
      items: [],
    });

    return container!.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: systemInfoWidget.loading,
    failed: systemInfoWidget.failed,
    title: _('System info'),
    items: [
      {
        key: _('Active Connections'),
        value: String(systemInfoWidget.data.connections),
      },
      {
        key: _('Memory Usage'),
        value: String(prettyBytes(systemInfoWidget.data.memory)),
      },
    ],
  });

  container!.replaceChildren(renderedWidget);
}

async function renderServicesInfoWidget() {
  logger.debug('[DASHBOARD]', 'renderServicesInfoWidget');
  const servicesInfoWidget = store.get().servicesInfoWidget;

  const container = document.getElementById('dashboard-widget-service-info');

  if (servicesInfoWidget.loading || servicesInfoWidget.failed) {
    const renderedWidget = renderWidget({
      loading: servicesInfoWidget.loading,
      failed: servicesInfoWidget.failed,
      title: '',
      items: [],
    });

    return container!.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: servicesInfoWidget.loading,
    failed: servicesInfoWidget.failed,
    title: _('Services info'),
    items: [
      {
        key: _('NetShift'),
        value: servicesInfoWidget.data.netshift
          ? _('✔ Enabled')
          : _('✘ Disabled'),
        attributes: {
          class: servicesInfoWidget.data.netshift
            ? 'pdk_dashboard-page__widgets-section__item__row--success'
            : 'pdk_dashboard-page__widgets-section__item__row--error',
        },
      },
      {
        key: _('Sing-box'),
        value: servicesInfoWidget.data.singbox
          ? _('✔ Running')
          : _('✘ Stopped'),
        attributes: {
          class: servicesInfoWidget.data.singbox
            ? 'pdk_dashboard-page__widgets-section__item__row--success'
            : 'pdk_dashboard-page__widgets-section__item__row--error',
        },
      },
    ],
  });

  container!.replaceChildren(renderedWidget);
}

async function onStoreUpdate(
  next: StoreType,
  prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.sectionsWidget) {
    renderSectionsWidget();
  }

  if (diff.bandwidthWidget) {
    renderBandwidthWidget();
  }

  if (diff.trafficTotalWidget) {
    renderTrafficTotalWidget();
  }

  if (diff.systemInfoWidget) {
    renderSystemInfoWidget();
  }

  if (diff.servicesInfoWidget) {
    renderServicesInfoWidget();
  }
}

async function onPageMount() {
  // Cleanup before mount
  onPageUnmount();

  // Add new listener
  store.subscribe(onStoreUpdate);

  // The page reset above also reset the view choice to what it was when the page
  // was loaded: take the saved one (it may have been changed since).
  store.set({
    sectionsWidget: {
      ...store.get().sectionsWidget,
      ...loadDashboardViewPrefs(),
    },
  });

  // Initial sections fetch
  await fetchDashboardSections();
  await fetchServicesInfo();
  await connectToClashSockets();
}

function onPageUnmount() {
  // Remove old listener
  store.unsubscribe(onStoreUpdate);
  // Clear store
  store.reset([
    'bandwidthWidget',
    'trafficTotalWidget',
    'systemInfoWidget',
    'servicesInfoWidget',
    'sectionsWidget',
  ]);
  socket.resetAll();
}

function registerLifecycleListeners() {
  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DASHBOARD]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      const isDashboardVisible = next.tabService.current === 'dashboard';

      if (isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

const UPDATE_NOTICE_REFRESH_WAIT = 25000;

function renderUpdateNotice(notice: UpdateNotice) {
  const container = document.getElementById('dashboard-update-notice');

  if (!container) {
    return;
  }

  const items = notice.enabled ? getOutdatedComponents(notice) : [];

  if (items.length === 0) {
    container.replaceChildren();

    return;
  }

  const names = {
    netshift: _('NetShift'),
    sing_box: _('Sing-box'),
  };

  container.replaceChildren(
    E('div', { class: 'card pdk_dashboard-page__update-notice' }, [
      E('b', {}, _('A newer version is available')),
      ...items.map((item) =>
        E(
          'div',
          {},
          `${names[item.component]}: ${item.current} → ${item.latest}`,
        ),
      ),
      E(
        'div',
        { class: 'pdk_dashboard-page__update-notice__hint' },
        _('Update it in the Component Manager tab.'),
      ),
    ]),
  );
}

async function loadUpdateNotice() {
  try {
    const first = await NetShiftShellMethods.getUpdateNotice();
    const notice = first.success ? parseUpdateNotice(first.data) : null;

    if (!notice) {
      return;
    }

    renderUpdateNotice(notice);

    if (!shouldRefreshUpdateNotice(notice)) {
      return;
    }

    await NetShiftShellMethods.refreshUpdateNotice();
    await new Promise((resolve) =>
      setTimeout(resolve, UPDATE_NOTICE_REFRESH_WAIT),
    );

    const second = await NetShiftShellMethods.getUpdateNotice();

    if (second.success) {
      renderUpdateNotice(parseUpdateNotice(second.data));
    }
  } catch (e) {
    logger.error('[DASHBOARD]', 'loadUpdateNotice: failed', e);
  }
}

async function loadPinGuardEvents() {
  const container = document.getElementById('dashboard-pin-guard');

  if (!container) {
    return;
  }

  try {
    const response = await NetShiftShellMethods.getPinGuardEvents();
    const events = response.success
      ? recentPinGuardEvents(
          parsePinGuardEvents(response.data),
          Math.floor(Date.now() / 1000),
        )
      : [];

    container.replaceChildren(
      ...(events.length === 0
        ? []
        : [
            E('div', { class: 'card pdk_dashboard-page__pin-guard' }, [
              E('b', {}, _('A dead server was left')),
              ...events.map((event) =>
                E(
                  'div',
                  {},
                  `${event.section}: ${event.from} ${_('stopped answering, the automatic choice is on again')}`,
                ),
              ),
            ]),
          ]),
    );
  } catch (e) {
    logger.error('[DASHBOARD]', 'loadPinGuardEvents: failed', e);
  }
}

export async function initController(): Promise<void> {
  onMount('dashboard-status').then(() => {
    logger.debug('[DASHBOARD]', 'initController', 'onMount');
    onPageMount();
    void loadUpdateNotice();
    void loadPinGuardEvents();
    registerLifecycleListeners();
  });
}

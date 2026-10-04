import {
  getClashWsUrl,
  onMount,
  preserveScrollForPage,
} from '../../../helpers';
import { prettyBytes } from '../../../helpers/prettyBytes';
import {
  loadDashboardViewPrefs,
  saveDashboardViewPrefs,
} from '../../../helpers/dashboardView';
import { CustomNetShiftMethods, NetShiftShellMethods } from '../../methods';
import { logger, socket, store, StoreType } from '../../services';
import { renderSections, renderWidget } from './partials';
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

// Renderer

async function renderSectionsWidget() {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');

  if (sectionsWidget.loading || sectionsWidget.failed) {
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
    });

    return preserveScrollForPage(() => {
      container!.replaceChildren(renderedWidget);
    });
  }

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

export async function initController(): Promise<void> {
  onMount('dashboard-status').then(() => {
    logger.debug('[DASHBOARD]', 'initController', 'onMount');
    onPageMount();
    registerLifecycleListeners();
  });
}

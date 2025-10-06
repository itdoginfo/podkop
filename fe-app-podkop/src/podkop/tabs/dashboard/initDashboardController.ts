import {
  getDashboardSections,
  getPodkopStatus,
  getSingboxStatus,
} from '../../methods';
import { renderOutboundGroup } from './renderer/renderOutboundGroup';
import { getClashWsUrl, onMount } from '../../../helpers';
import { renderDashboardWidget } from './renderer/renderWidget';
import {
  triggerLatencyGroupTest,
  triggerLatencyProxyTest,
  triggerProxySelector,
} from '../../../clash';
import { store, StoreType } from '../../../store';
import { socket } from '../../../socket';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { renderEmptyOutboundGroup } from './renderer/renderEmptyOutboundGroup';

// Fetchers

async function fetchDashboardSections() {
  store.set({
    dashboardSections: {
      ...store.get().dashboardSections,
      failed: false,
      loading: true,
    },
  });

  const { data, success } = await getDashboardSections();

  store.set({ dashboardSections: { loading: false, data, failed: !success } });
}

async function fetchServicesInfo() {
  const podkop = await getPodkopStatus();
  const singbox = await getSingboxStatus();

  store.set({
    services: {
      singbox: singbox.running,
      podkop: podkop.enabled,
    },
  });
}

async function connectToClashSockets() {
  socket.subscribe(`${getClashWsUrl()}/traffic?token=`, (msg) => {
    const parsedMsg = JSON.parse(msg);

    store.set({
      traffic: { up: parsedMsg.up, down: parsedMsg.down },
    });
  });

  socket.subscribe(`${getClashWsUrl()}/connections?token=`, (msg) => {
    const parsedMsg = JSON.parse(msg);

    store.set({
      connections: {
        connections: parsedMsg.connections,
        downloadTotal: parsedMsg.downloadTotal,
        uploadTotal: parsedMsg.uploadTotal,
        memory: parsedMsg.memory,
      },
    });
  });

  socket.subscribe(`${getClashWsUrl()}/memory?token=`, (msg) => {
    store.set({
      memory: { inuse: msg.inuse, oslimit: msg.oslimit },
    });
  });
}

// Handlers

async function handleChooseOutbound(selector: string, tag: string) {
  await triggerProxySelector(selector, tag);
  await fetchDashboardSections();
}

async function handleTestGroupLatency(tag: string) {
  await triggerLatencyGroupTest(tag);
  await fetchDashboardSections();
}

async function handleTestProxyLatency(tag: string) {
  await triggerLatencyProxyTest(tag);
  await fetchDashboardSections();
}

function replaceTestLatencyButtonsWithSkeleton() {
  document
    .querySelectorAll('.dashboard-sections-grid-item-test-latency')
    .forEach((el) => {
      const newDiv = document.createElement('div');
      newDiv.className = 'skeleton';
      newDiv.style.width = '99px';
      newDiv.style.height = '28px';
      el.replaceWith(newDiv);
    });
}

// Renderer

async function renderDashboardSections() {
  const dashboardSections = store.get().dashboardSections;
  const container = document.getElementById('dashboard-sections-grid');

  if (dashboardSections.failed) {
    const rendered = renderEmptyOutboundGroup();

    return container!.replaceChildren(rendered);
  }

  const renderedOutboundGroups = dashboardSections.data.map((section) =>
    renderOutboundGroup({
      section,
      onTestLatency: (tag) => {
        replaceTestLatencyButtonsWithSkeleton();

        if (section.withTagSelect) {
          return handleTestGroupLatency(tag);
        }

        return handleTestProxyLatency(tag);
      },
      onChooseOutbound: (selector, tag) => {
        handleChooseOutbound(selector, tag);
      },
    }),
  );

  container!.replaceChildren(...renderedOutboundGroups);
}

async function renderTrafficWidget() {
  const traffic = store.get().traffic;

  const container = document.getElementById('dashboard-widget-traffic');
  const renderedWidget = renderDashboardWidget({
    title: 'Traffic',
    items: [
      { key: 'Uplink', value: `${prettyBytes(traffic.up)}/s` },
      { key: 'Downlink', value: `${prettyBytes(traffic.down)}/s` },
    ],
  });

  container!.replaceChildren(renderedWidget);
}

async function renderTrafficTotalWidget() {
  const connections = store.get().connections;

  const container = document.getElementById('dashboard-widget-traffic-total');
  const renderedWidget = renderDashboardWidget({
    title: 'Traffic Total',
    items: [
      { key: 'Uplink', value: String(prettyBytes(connections.uploadTotal)) },
      {
        key: 'Downlink',
        value: String(prettyBytes(connections.downloadTotal)),
      },
    ],
  });

  container!.replaceChildren(renderedWidget);
}

async function renderSystemInfoWidget() {
  const connections = store.get().connections;

  const container = document.getElementById('dashboard-widget-system-info');
  const renderedWidget = renderDashboardWidget({
    title: 'System info',
    items: [
      {
        key: 'Active Connections',
        value: String(connections.connections.length),
      },
      { key: 'Memory Usage', value: String(prettyBytes(connections.memory)) },
    ],
  });

  container!.replaceChildren(renderedWidget);
}

async function renderServiceInfoWidget() {
  const services = store.get().services;

  const container = document.getElementById('dashboard-widget-service-info');
  const renderedWidget = renderDashboardWidget({
    title: 'Services info',
    items: [
      {
        key: 'Podkop',
        value: services.podkop ? '✔ Enabled' : '✘ Disabled',
        attributes: {
          class: services.podkop
            ? 'pdk_dashboard-page__widgets-section__item__row--success'
            : 'pdk_dashboard-page__widgets-section__item__row--error',
        },
      },
      {
        key: 'Sing-box',
        value: services.singbox ? '✔ Running' : '✘ Stopped',
        attributes: {
          class: services.singbox
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
  if (diff?.dashboardSections) {
    renderDashboardSections();
  }

  if (diff?.traffic) {
    renderTrafficWidget();
  }

  if (diff?.connections) {
    renderTrafficTotalWidget();
    renderSystemInfoWidget();
  }

  if (diff?.services) {
    renderServiceInfoWidget();
  }
}

export async function initDashboardController(): Promise<void> {
  onMount('dashboard-status').then(() => {
    // Remove old listener
    store.unsubscribe(onStoreUpdate);
    // Clear store
    store.reset();

    // Add new listener
    store.subscribe(onStoreUpdate);

    // Initial sections fetch
    fetchDashboardSections();
    fetchServicesInfo();
    connectToClashSockets();
  });
}

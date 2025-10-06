import {
  getDashboardSections,
  getPodkopStatus,
  getSingboxStatus,
} from '../podkop/methods';
import { renderOutboundGroup } from './renderer/renderOutboundGroup';
import { getClashWsUrl, onMount } from '../helpers';
import { store } from '../store';
import { socket } from '../socket';
import { renderDashboardWidget } from './renderer/renderWidget';
import { prettyBytes } from '../helpers/prettyBytes';

// Fetchers

async function fetchDashboardSections() {
  const sections = await getDashboardSections();

  store.set({ sections });
}

async function fetchServicesInfo() {
  const podkop = await getPodkopStatus();
  const singbox = await getSingboxStatus();

  console.log('podkop', podkop);
  console.log('singbox', singbox);
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

// Renderer

async function renderDashboardSections() {
  const sections = store.get().sections;
  console.log('render dashboard sections group');
  const container = document.getElementById('dashboard-sections-grid');
  const renderedOutboundGroups = sections.map(renderOutboundGroup);

  container!.replaceChildren(...renderedOutboundGroups);
}

async function renderTrafficWidget() {
  const traffic = store.get().traffic;
  console.log('render dashboard traffic widget');
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
  console.log('render dashboard traffic total widget');
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
  console.log('render dashboard system info widget');
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
  console.log('render dashboard service info widget');
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

export async function initDashboardController(): Promise<void> {
  store.subscribe((next, prev, diff) => {
    console.log('Store changed', { prev, next, diff });

    // Update sections render
    if (diff?.sections) {
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
  });

  onMount('dashboard-status').then(() => {
    console.log('Mounting dashboard');
    // Initial sections fetch
    fetchDashboardSections();
    fetchServicesInfo();
    connectToClashSockets();
  });
}

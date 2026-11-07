import viewSource from '../../../../luci-app-netshift/htdocs/luci-static/resources/view/netshift/devices.js?raw';
import { describe, expect, it, vi, afterEach } from 'vitest';
import * as routing from '../deviceRouting';
import * as lanDevices from '../lanDevices';
import { validateIP, validateIPV4 } from '../../validators/validateIp';

// LuCI supplies E(), UCI and form widgets at runtime. Keep the tree and widget
// values here, while running the actual view and routing helpers.
interface Attributes {
  [key: string]: unknown;
  input?: (event: { target: { value: string } }) => void;
  change?: (event: { target: { value: string } }) => void;
  click?: () => void;
}

class Node {
  children: Node[] = [];
  isConnected = true;
  listeners = new Map<string, () => void>();
  pane?: Node;
  style = { display: '' };
  get value() {
    return String(this.attrs.value ?? '');
  }
  constructor(
    public tag: string,
    public attrs: Attributes = {},
    public text = '',
  ) {}
  appendChild(child: Node) {
    this.children.push(child);
  }
  replaceChildren(...children: Node[]) {
    this.children = children;
  }
  closest() {
    return this.pane;
  }
  addEventListener(name: string, callback: () => void) {
    this.listeners.set(name, callback);
  }
  removeEventListener(name: string) {
    this.listeners.delete(name);
  }
  all(tag: string): Node[] {
    return this.children.flatMap((child) => [
      ...(child.tag === tag ? [child] : []),
      ...child.all(tag),
    ]);
  }
}

function E(tag: string, attrs: Attributes = {}, content: unknown = []) {
  const node = new Node(tag, attrs);
  for (const child of Array.isArray(content) ? content : [content]) {
    node.appendChild(
      child instanceof Node ? child : new Node('#text', {}, String(child)),
    );
  }
  return node;
}

async function setup({
  ipv6 = true,
  disabled = false,
  addresses = ['192.168.1.10', 'fd00::10'],
  staticHosts = [] as lanDevices.StaticLease[],
} = {}) {
  const values = {
    main: [addresses[0], '192.168.1.0/24'],
    second: ['192.168.1.99'],
    excluded: [addresses[1]],
  };
  const writes: string[] = [];
  const commands: string[][] = [];
  const pane = new Node('pane');
  let mounted: () => Promise<void>;
  let removal: () => void;
  let disconnected = false;
  const hints = vi.fn(async () => ({
    getMACHints: () => [['AA:BB:CC:00:00:01', 'PC']],
    getIPAddrByMACAddr: () => addresses[0],
    getIP6AddrByMACAddr: () => addresses[1],
  }));
  const widget = (key: keyof typeof values) => ({
    getValue: () => values[key],
    setValue: (value: string[]) => {
      values[key] = value;
      writes.push(key);
    },
  });
  const sections = {
    children: [
      {
        option: 'fully_routed_ips',
        getUIElement: (key: 'main' | 'second') => widget(key),
      },
    ],
  };
  const settings = {
    children: [
      {
        option: 'routing_excluded_ips',
        getUIElement: () => widget('excluded'),
      },
    ],
  };
  const option: { render?: () => Promise<Node> } = {};
  const main = {
    ...routing,
    ...lanDevices,
    validateIP,
    validateIPV4,
    onFirstVisible: (node: Node, load: () => Promise<void>) => {
      node.pane = pane;
      mounted = load;
    },
    executeShellCommand: async ({ args }: { args: string[] }) => {
      commands.push(args);
      return {
        stdout: JSON.stringify({
          subnets: [],
          static_hosts: staticHosts,
          ok: true,
        }),
      };
    },
  };
  vi.stubGlobal(
    'MutationObserver',
    class {
      constructor(callback: () => void) {
        removal = callback;
      }
      observe() {}
      disconnect() {
        disconnected = true;
      }
    },
  );
  vi.stubGlobal('document', { body: {} });
  const modals: Node[][] = [];
  const view = new Function(
    'main',
    'uci',
    'network',
    'form',
    'ui',
    'baseclass',
    'E',
    '_',
    viewSource,
  )(
    main,
    {
      sections: () => [
        {
          '.name': 'main',
          connection_type: 'proxy',
          disabled: disabled ? '1' : '0',
        },
        { '.name': 'second', connection_type: 'vpn' },
      ],
      get: (_config: string, _section: string, key: string) =>
        key === 'enable_ipv6' ? (ipv6 ? '1' : '0') : [],
    },
    { getHostHints: hints },
    {},
    {
      showModal: (_title: string, children: Node[]) => modals.push(children),
      hideModal() {},
    },
    { extend: (entry: unknown) => entry },
    E,
    (text: string) => ({
      toString: () => text,
      format: (value: string) => text.replace('%s', value),
    }),
  );
  view.createDevicesContent({ option: () => option }, sections, settings);
  const root = await option.render!();
  await mounted!();
  const rows = () => root.all('tbody')[0].children;
  const pc = () =>
    rows().find((row) => row.all('#text').some((node) => node.text === 'PC'))!;
  return {
    root,
    pane,
    rows,
    pc,
    values,
    writes,
    hints,
    commands,
    modals,
    remove: () => {
      root.children[0].isConnected = false;
      removal!();
    },
    disconnected: () => disconnected,
  };
}

afterEach(() => vi.unstubAllGlobals());

describe('Devices LuCI view', () => {
  it('renders a group with both addresses and a read-only mixed route', async () => {
    const page = await setup();
    const row = page.pc();
    expect(row.all('#text').map((node) => node.text)).toContain('fd00::10');
    expect(row.all('button')).toHaveLength(1);
    expect(
      row.all('option').find((node) => node.attrs.selected === '')?.attrs,
    ).toMatchObject({ value: routing.DEVICE_ROUTE_MIXED, disabled: '' });
    expect(page.writes).toEqual([]);
    page.root.all('input')[0].attrs.input!({ target: { value: 'fd00::10' } });
    expect(page.rows()).toHaveLength(1);
    expect(page.pc()).toBeDefined();
    expect(page.writes).toEqual([]);
  });

  it('changes both addresses using current widget values and keeps CIDRs', async () => {
    const page = await setup();
    page.values.second.push('192.168.1.88');
    page.pc().all('select')[0].attrs.change!({ target: { value: 'second' } });
    expect(page.values).toEqual({
      main: ['192.168.1.0/24'],
      second: ['192.168.1.99', '192.168.1.88', '192.168.1.10', 'fd00::10'],
      excluded: [],
    });
    expect(page.writes).toEqual(['main', 'second', 'excluded']);
  });

  it('refreshes widget state on tab activation, without fetching hints again, and cleans up', async () => {
    const page = await setup();
    page.values.main = ['192.168.1.10', 'fd00::10'];
    page.values.excluded = [];
    page.pane.listeners.get('cbi-tab-active')!();
    expect(
      page
        .pc()
        .all('option')
        .find((node) => node.attrs.selected === '')?.attrs.value,
    ).toBe('main');
    expect(page.hints).toHaveBeenCalledTimes(1);
    expect(page.writes).toEqual([]);
    page.remove();
    expect(page.pane.listeners.size).toBe(0);
    expect(page.disconnected()).toBe(true);
  });

  it('does not offer a disabled section as a new target for mixed routes', async () => {
    const page = await setup({ disabled: true });
    expect(
      page
        .pc()
        .all('option')
        .map((node) => node.attrs.value),
    ).not.toContain('main');
  });
  it('pins the primary IPv4 even when IPv6 was discovered first', async () => {
    const page = await setup({ addresses: ['fd00::10', '192.168.1.10'] });
    page.pc().all('button')[0].attrs.click!();
    const modal = E('div', {}, page.modals[0]);
    expect(modal.all('input')[0].value).toBe('192.168.1.10');
    modal.all('button')[1].attrs.click!();
    await vi.waitFor(() =>
      expect(page.commands).toContainEqual([
        'dhcp_host_set',
        'AA:BB:CC:00:00:01',
        '192.168.1.10',
        'PC',
      ]),
    );
  });

  it('does not offer new IPv4 pinning for a group without IPv4', async () => {
    const page = await setup({ addresses: ['fd00::10', 'fd00::11'] });
    expect(page.pc().all('button')).toHaveLength(0);
  });

  it('edits an existing static lease using its IP rather than a discovered address', async () => {
    const page = await setup({
      staticHosts: [
        {
          section: 'lease1',
          macs: ['AA:BB:CC:00:00:01'],
          ip: '192.168.1.77',
          name: 'saved',
        },
      ],
    });
    expect(page.pc().all('button')).toHaveLength(2);
    page.pc().all('button')[0].attrs.click!();
    const modal = E('div', {}, page.modals[0]);
    expect(modal.all('input').map((node) => node.value)).toEqual([
      '192.168.1.77',
      'saved',
    ]);
  });

  it('retains a uniform disabled route for display', async () => {
    const page = await setup({ disabled: true });
    page.values.main = ['192.168.1.10', 'fd00::10'];
    page.values.excluded = [];
    page.pane.listeners.get('cbi-tab-active')!();
    expect(
      page
        .pc()
        .all('option')
        .find((node) => node.attrs.selected === '')?.attrs.value,
    ).toBe('main');
    expect(page.writes).toEqual([]);
  });

  it('keeps listed IPv6 offline when IPv6 discovery is disabled', async () => {
    const page = await setup({ ipv6: false });
    const text = page
      .pc()
      .all('#text')
      .map((node) => node.text);
    expect(text).toContain('192.168.1.10');
    expect(text).not.toContain('fd00::10');
    expect(
      page
        .rows()
        .some((row) =>
          row.all('#text').some((node) => node.text === 'fd00::10'),
        ),
    ).toBe(true);
  });
});

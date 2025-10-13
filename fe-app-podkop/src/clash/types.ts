// eslint-disable-next-line @typescript-eslint/no-namespace
export namespace ClashAPI {
  export interface Version {
    meta: boolean;
    premium: boolean;
    version: string;
  }

  export interface Config {
    port: number;
    'socks-port': number;
    'redir-port': number;
    'tproxy-port': number;
    'mixed-port': number;
    'allow-lan': boolean;
    'bind-address': string;
    mode: 'Rule' | 'Global' | 'Direct';
    'mode-list': string[];
    'log-level': 'debug' | 'info' | 'warn' | 'error';
    ipv6: boolean;
    tun: null | Record<string, unknown>;
  }

  export interface ProxyHistoryEntry {
    time: string;
    delay: number;
  }

  export interface ProxyBase {
    type: string;
    name: string;
    udp: boolean;
    history: ProxyHistoryEntry[];
    now?: string;
    all?: string[];
  }

  export interface Proxies {
    proxies: Record<string, ProxyBase>;
  }

  export type Delays = Record<string, number>;
}

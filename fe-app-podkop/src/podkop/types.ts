// eslint-disable-next-line @typescript-eslint/no-namespace
export namespace Podkop {
  export interface Outbound {
    code: string;
    displayName: string;
    latency: number;
    type: string;
    selected: boolean;
  }

  export interface OutboundGroup {
    withTagSelect: boolean;
    code: string;
    displayName: string;
    outbounds: Outbound[];
  }

  export interface ConfigProxyUrlTestSection {
    connection_type: 'proxy';
    proxy_config_type: 'urltest';
    urltest_proxy_links: string[];
  }

  export interface ConfigProxyUrlSection {
    connection_type: 'proxy';
    proxy_config_type: 'url';
    proxy_string: string;
  }

  export interface ConfigProxyOutboundSection {
    connection_type: 'proxy';
    proxy_config_type: 'outbound';
    outbound_json: string;
  }

  export interface ConfigVpnSection {
    connection_type: 'vpn';
    interface: string;
  }

  export interface ConfigBlockSection {
    connection_type: 'block';
  }

  export type ConfigBaseSection =
    | ConfigProxyUrlTestSection
    | ConfigProxyUrlSection
    | ConfigProxyOutboundSection
    | ConfigVpnSection
    | ConfigBlockSection;

  export type ConfigSection = ConfigBaseSection & {
    '.name': string;
    '.type': 'settings' | 'section';
  };
}

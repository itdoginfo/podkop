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

  export interface MethodSuccessResponse<T> {
    success: true;
    data: T;
  }

  export interface MethodFailureResponse {
    success: false;
    error: string;
  }

  export type MethodResponse<T> =
    | MethodSuccessResponse<T>
    | MethodFailureResponse;

  export interface DnsCheckResult {
    dns_type: 'udp' | 'doh' | 'dot';
    dns_server: string;
    dns_status: 0 | 1;
    local_dns_status: 0 | 1;
    bootstrap_dns_server: string;
    bootstrap_dns_status: 0 | 1;
    dhcp_has_dns_server: 0 | 1;
  }

  export interface NftRulesCheckResult {
    table_exist: 0 | 1;
    rules_mangle_exist: 0 | 1;
    rules_mangle_counters: 0 | 1;
    rules_mangle_output_exist: 0 | 1;
    rules_mangle_output_counters: 0 | 1;
    rules_proxy_exist: 0 | 1;
    rules_proxy_counters: 0 | 1;
    rules_other_mark_exist: 0 | 1;
  }

  export interface SingBoxCheckResult {
    sing_box_installed: 0 | 1;
    sing_box_version_ok: 0 | 1;
    sing_box_service_exist: 0 | 1;
    sing_box_autostart_disabled: 0 | 1;
    sing_box_process_running: 0 | 1;
    sing_box_ports_listening: 0 | 1;
  }
}

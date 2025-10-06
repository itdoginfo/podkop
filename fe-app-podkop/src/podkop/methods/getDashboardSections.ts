import { Podkop } from '../types';
import { getConfigSections } from './getConfigSections';
import { getClashProxies } from '../../clash';
import { getProxyUrlName } from '../../helpers';

export async function getDashboardSections(): Promise<Podkop.OutboundGroup[]> {
  const configSections = await getConfigSections();
  const clashProxies = await getClashProxies();

  const clashProxiesData = clashProxies.success
    ? clashProxies.data
    : { proxies: [] };

  const proxies = Object.entries(clashProxiesData.proxies).map(
    ([key, value]) => ({
      code: key,
      value,
    }),
  );

  return configSections
    .filter((section) => section.mode !== 'block')
    .map((section) => {
      if (section.mode === 'proxy') {
        if (section.proxy_config_type === 'url') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            displayName: section['.name'],
            outbounds: [
              {
                code: outbound?.code || section['.name'],
                displayName:
                  getProxyUrlName(section.proxy_string) ||
                  outbound?.value?.name ||
                  '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
              },
            ],
          };
        }

        if (section.proxy_config_type === 'outbound') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            displayName: section['.name'],
            outbounds: [
              {
                code: outbound?.code || section['.name'],
                displayName:
                  decodeURIComponent(JSON.parse(section.outbound_json)?.tag) ||
                  outbound?.value?.name ||
                  '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
              },
            ],
          };
        }

        if (section.proxy_config_type === 'urltest') {
          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-urltest-out`,
          );

          const outbounds = (outbound?.value?.all ?? [])
            .map((code) => proxies.find((item) => item.code === code))
            .map((item, index) => ({
              code: item?.code || '',
              displayName:
                getProxyUrlName(section.urltest_proxy_links?.[index]) ||
                item?.value?.name ||
                '',
              latency: item?.value?.history?.[0]?.delay || 0,
              type: item?.value?.type || '',
              selected: selector?.value?.now === item?.code,
            }));

          return {
            withTagSelect: true,
            code: selector?.code || section['.name'],
            displayName: section['.name'],
            outbounds: [
              {
                code: outbound?.code || '',
                displayName: 'Fastest',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: selector?.value?.now === outbound?.code,
              },
              ...outbounds,
            ],
          };
        }
      }

      if (section.mode === 'vpn') {
        const outbound = proxies.find(
          (proxy) => proxy.code === `${section['.name']}-out`,
        );

        return {
          withTagSelect: false,
          code: outbound?.code || section['.name'],
          displayName: section['.name'],
          outbounds: [
            {
              code: outbound?.code || section['.name'],
              displayName: section.interface || outbound?.value?.name || '',
              latency: outbound?.value?.history?.[0]?.delay || 0,
              type: outbound?.value?.type || '',
              selected: true,
            },
          ],
        };
      }

      return {
        withTagSelect: false,
        code: section['.name'],
        displayName: section['.name'],
        outbounds: [],
      };
    });
}

import { getConfigSections } from './getConfigSections';
import { Podkop } from '../../types';
import { getProxyUrlName, splitProxyString } from '../../../helpers';
import { PodkopShellMethods } from '../shell';

interface IGetDashboardSectionsResponse {
  success: boolean;
  data: Podkop.OutboundGroup[];
}

export async function getDashboardSections(): Promise<IGetDashboardSectionsResponse> {
  const configSections = await getConfigSections();
  const clashProxies = await PodkopShellMethods.getClashApiProxies();

  if (!clashProxies.success) {
    return {
      success: false,
      data: [],
    };
  }

  const proxies = Object.entries(clashProxies.data.proxies).map(
    ([key, value]) => ({
      code: key,
      value,
    }),
  );

  const data = configSections
    .filter(
      (section) =>
        section.connection_type !== 'block' && section['.type'] !== 'settings',
    )
    .map((section) => {
      if (section.connection_type === 'proxy') {
        if (section.proxy_config_type === 'url') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          const activeConfigs = splitProxyString(section.proxy_string);

          const proxyDisplayName =
            getProxyUrlName(activeConfigs?.[0]) || outbound?.value?.name || '';

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            displayName: section['.name'],
            outbounds: [
              {
                code: outbound?.code || section['.name'],
                displayName: proxyDisplayName,
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

          const parsedOutbound = JSON.parse(section.outbound_json);
          const parsedTag = parsedOutbound?.tag
            ? decodeURIComponent(parsedOutbound?.tag)
            : undefined;
          const proxyDisplayName = parsedTag || outbound?.value?.name || '';

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            displayName: section['.name'],
            outbounds: [
              {
                code: outbound?.code || section['.name'],
                displayName: proxyDisplayName,
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
              },
            ],
          };
        }

        if (section.proxy_config_type === 'selector') {
          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          const links = section.selector_proxy_links ?? [];

          const outbounds = links
            .map((link, index) => ({
              link,
              outbound: proxies.find(
                (item) => item.code === `${section['.name']}-${index + 1}-out`,
              ),
            }))
            .map((item) => ({
              code: item?.outbound?.code || '',
              displayName:
                getProxyUrlName(item.link) || item?.outbound?.value?.name || '',
              latency: item?.outbound?.value?.history?.[0]?.delay || 0,
              type: item?.outbound?.value?.type || '',
              selected: selector?.value?.now === item?.outbound?.code,
            }));

          return {
            withTagSelect: true,
            code: selector?.code || section['.name'],
            displayName: section['.name'],
            outbounds,
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
                displayName: _('Fastest'),
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: selector?.value?.now === outbound?.code,
              },
              ...outbounds,
            ],
          };
        }
      }

      if (section.connection_type === 'vpn') {
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

  return {
    success: true,
    data,
  };
}

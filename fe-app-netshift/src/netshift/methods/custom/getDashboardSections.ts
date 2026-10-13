import { getConfigSections } from './getConfigSections';
import { NetShift } from '../../types';
import {
  getProxyUrlName,
  splitProxyString,
  withCountryFlag,
} from '../../../helpers';
import { NetShiftShellMethods } from '../shell';
import { buildSubscriptionOutboundGroup } from './buildSubscriptionOutboundGroup';

interface IGetDashboardSectionsResponse {
  success: boolean;
  data: NetShift.OutboundGroup[];
}

// The backend walks a pasted list with the shell's word splitting (any
// whitespace, not only line breaks), skips blank entries, and names each member
// outbound after the position of the entry: the same split gives the same numbers.
function splitTextLinks(text?: string): string[] {
  return (text ?? '').split(/\s+/).filter(Boolean);
}

function linkIndexOfTag(section: string, tag?: string): number {
  const match = tag?.slice(section.length + 1).match(/^(\d+)-out$/);

  return match ? Number(match[1]) - 1 : -1;
}

export async function getDashboardSections(): Promise<IGetDashboardSectionsResponse> {
  const configSections = await getConfigSections();
  const clashProxies = await NetShiftShellMethods.getClashApiProxies();

  if (!clashProxies.success) {
    return {
      success: false,
      data: [],
    };
  }

  // Countries of manually added links (GeoIP option); an error just means no flags.
  const geoipResponse = await NetShiftShellMethods.getGeoipFlags();
  const geoipFlags: Record<string, string> =
    geoipResponse.success &&
    geoipResponse.data &&
    typeof geoipResponse.data === 'object'
      ? geoipResponse.data
      : {};

  const proxies = Object.entries(clashProxies.data.proxies).map(
    ([key, value]) => ({
      code: key,
      value,
    }),
  );

  const data = configSections
    .filter(
      (section) =>
        section.connection_type !== 'block' &&
        section.connection_type !== 'exclusion' &&
        section.connection_type !== 'dns' &&
        section['.type'] !== 'settings' &&
        section.disabled !== '1',
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

        if (
          section.proxy_config_type === 'selector' ||
          section.proxy_config_type === 'selector_text'
        ) {
          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          const isText = section.proxy_config_type === 'selector_text';
          const links = isText
            ? splitTextLinks(section.selector_proxy_links_text)
            : (section.selector_proxy_links ?? []);

          const outbounds = links
            .map((link, index) => ({
              link,
              outbound: proxies.find(
                (item) => item.code === `${section['.name']}-${index + 1}-out`,
              ),
            }))
            // A pasted line the backend skipped (unsupported link) has no
            // outbound: it must not show up as an empty server.
            .filter((item) => !isText || item.outbound)
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

        if (
          section.proxy_config_type === 'urltest' ||
          section.proxy_config_type === 'urltest_text'
        ) {
          const urltestLinks =
            section.proxy_config_type === 'urltest_text'
              ? splitTextLinks(section.urltest_proxy_links_text)
              : (section.urltest_proxy_links ?? []);

          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-urltest-out`,
          );

          // Links are matched to members by tag (<section>-<n>-out), so a
          // skipped link does not shift the names of the ones after it.
          const outbounds = (outbound?.value?.all ?? [])
            .map((code) => proxies.find((item) => item.code === code))
            .map((item) => ({
              code: item?.code || '',
              displayName:
                getProxyUrlName(
                  urltestLinks[linkIndexOfTag(section['.name'], item?.code)] ??
                    '',
                ) ||
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

        if (section.proxy_config_type === 'subscription') {
          // The dashboard refresh buttons address the backend by the UCI
          // section name.
          return {
            ...buildSubscriptionOutboundGroup(section['.name'], proxies),
            isSubscription: true,
            sectionName: section['.name'],
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

  const flagged = data.map((group) => ({
    ...group,
    outbounds: group.outbounds.map((outbound) => ({
      ...outbound,
      displayName: withCountryFlag(
        outbound.displayName,
        geoipFlags[outbound.code],
      ),
    })),
  }));

  return {
    success: true,
    data: flagged,
  };
}

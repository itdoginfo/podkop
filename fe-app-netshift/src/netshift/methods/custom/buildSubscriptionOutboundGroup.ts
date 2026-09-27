import { ClashAPI, NetShift } from '../../types';

interface ProxyEntry {
  code: string;
  value: ClashAPI.ProxyBase;
}

// Mirrors SB_SUBSCRIPTION_FEED_GROUP_TAG_PREFIX in the backend constants.sh:
// per-subscription urltest tags are "<prefix><subscription name>".
export const SUBSCRIPTION_FEED_GROUP_TAG_PREFIX = '⚡ ';

function isGroupType(item?: ProxyEntry) {
  const type = item?.value?.type?.toLowerCase();

  return type === 'urltest' || type === 'selector';
}

function isUrlTest(item?: ProxyEntry) {
  return item?.value?.type?.toLowerCase() === 'urltest';
}

function stripFeedPrefix(name: string) {
  return name.startsWith(SUBSCRIPTION_FEED_GROUP_TAG_PREFIX)
    ? name.slice(SUBSCRIPTION_FEED_GROUP_TAG_PREFIX.length)
    : name;
}

export function buildSubscriptionOutboundGroup(
  sectionName: string,
  proxies: ProxyEntry[],
): NetShift.OutboundGroup {
  const byCode = new Map(proxies.map((proxy) => [proxy.code, proxy]));
  const selector = byCode.get(`${sectionName}-out`);
  const legacyFastestCode = `${sectionName}-urltest-out`;
  const fallbackUrltest = byCode.get(legacyFastestCode);
  const selectedCode = selector?.value?.now;

  function toOutbound(
    item: ProxyEntry,
    displayName?: string,
  ): NetShift.Outbound {
    return {
      code: item.code,
      displayName: displayName ?? (item.value?.name || ''),
      latency: item.value?.history?.[0]?.delay || 0,
      type: item.value?.type || '',
      selected: selectedCode === item.code,
    };
  }

  const selectorCodes = selector?.value?.all ?? [];
  const selectorItems = selectorCodes.flatMap((code) => {
    const item = byCode.get(code);

    return item ? [item] : [];
  });

  if (selectorItems.length === 0 && fallbackUrltest) {
    const fallbackOutbounds = (fallbackUrltest.value?.all ?? []).flatMap(
      (code) => {
        const item = byCode.get(code);

        return item ? [toOutbound(item)] : [];
      },
    );

    return {
      withTagSelect: true,
      code: selector?.code || sectionName,
      displayName: sectionName,
      outbounds: [
        toOutbound(fallbackUrltest, _('Fastest')),
        ...fallbackOutbounds,
      ],
    };
  }

  // A subscription block is a urltest in the selector (other than the
  // section-wide one) whose members are all plain nodes the selector offers
  // too. Country/prefix groups do not qualify: their members are not in the
  // selector, and the cross-group Fastest has urltests as members.
  const selectorCodeSet = new Set(selectorCodes);
  const feedGroups = selectorItems.filter(
    (item) =>
      item.code !== legacyFastestCode &&
      isUrlTest(item) &&
      (item.value?.all?.length ?? 0) > 0 &&
      (item.value?.all ?? []).every(
        (code) => selectorCodeSet.has(code) && !isGroupType(byCode.get(code)),
      ),
  );
  const groupedCodes = new Set(
    feedGroups.flatMap((item) => [item.code, ...(item.value?.all ?? [])]),
  );

  const topLevel = selectorItems
    .filter((item) => !groupedCodes.has(item.code))
    .map((item) =>
      toOutbound(
        item,
        item.code === legacyFastestCode ? _('Fastest') : undefined,
      ),
    );

  const subgroups = feedGroups.map((item) => ({
    code: item.code,
    displayName: stripFeedPrefix(item.value?.name || item.code),
    outbounds: [
      toOutbound(item, _('Fastest')),
      ...(item.value?.all ?? []).flatMap((code) => {
        const member = byCode.get(code);

        return member ? [toOutbound(member)] : [];
      }),
    ],
  }));

  return {
    withTagSelect: true,
    code: selector?.code || sectionName,
    displayName: sectionName,
    outbounds: [
      ...topLevel.filter((item) => item.type.toLowerCase() === 'urltest'),
      ...topLevel.filter((item) => item.type.toLowerCase() !== 'urltest'),
    ],
    ...(subgroups.length ? { subgroups } : {}),
  };
}

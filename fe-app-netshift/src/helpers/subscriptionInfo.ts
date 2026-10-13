// What a subscription panel reports about the account (netshift
// get_subscription_info): traffic used, the quota and when it ends.
export interface SubscriptionInfo {
  upload: number | null;
  download: number | null;
  total: number | null;
  expire: number | null;
  title: string | null;
}

export type SubscriptionInfoBySection = Record<string, SubscriptionInfo[]>;

const asNumberOrNull = (value: unknown): number | null =>
  typeof value === 'number' && Number.isFinite(value) ? value : null;

// The backend keys the info by the NAME OF THE UCI SECTION. On the dashboard that is the
// displayName of a section; its code is the tag of the selector outbound (main-out).
export function subscriptionInfoOf(
  info: SubscriptionInfoBySection,
  section: { displayName: string },
): SubscriptionInfo[] {
  return info[section.displayName] ?? [];
}

export function parseSubscriptionInfo(
  stdout: unknown,
): SubscriptionInfoBySection {
  let data: unknown = stdout;

  if (typeof stdout === 'string') {
    try {
      data = JSON.parse(stdout);
    } catch {
      return {};
    }
  }

  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return {};
  }

  const result: SubscriptionInfoBySection = {};

  for (const [section, entries] of Object.entries(data)) {
    if (!Array.isArray(entries)) {
      continue;
    }

    result[section] = entries
      .filter((entry) => entry && typeof entry === 'object')
      .map((entry) => ({
        upload: asNumberOrNull(entry.upload),
        download: asNumberOrNull(entry.download),
        total: asNumberOrNull(entry.total),
        expire: asNumberOrNull(entry.expire),
        title: typeof entry.title === 'string' ? entry.title : null,
      }));
  }

  return result;
}

export interface SubscriptionInfoLine {
  // Bytes used (upload + download); null when the panel reports no usage.
  used: number | null;
  // Quota in bytes; null when unlimited or not reported.
  total: number | null;
  // Percentage of the quota used (0-100), for a bar; null without a quota.
  percent: number | null;
  // Expiry date (YYYY-MM-DD); null when the account does not expire.
  expireDate: string | null;
  // Whole days left (rounded up); negative after the expiry.
  daysLeft: number | null;
  // The account is past its expiry date or out of traffic.
  exhausted: boolean;
  title: string | null;
}

const DAY_SECONDS = 86400;

// `now` is in seconds. A total or an expire of 0 means "unlimited" in the
// panels' convention.
export function describeSubscriptionInfo(
  info: SubscriptionInfo,
  now: number,
): SubscriptionInfoLine {
  const hasUsage = info.upload !== null || info.download !== null;
  const used = hasUsage ? (info.upload ?? 0) + (info.download ?? 0) : null;
  const total = info.total !== null && info.total > 0 ? info.total : null;
  const percent =
    total !== null && used !== null
      ? Math.min(100, Math.round((used / total) * 100))
      : null;

  let expireDate: string | null = null;
  let daysLeft: number | null = null;

  if (info.expire !== null && info.expire > 0) {
    expireDate = new Date(info.expire * 1000).toISOString().slice(0, 10);
    daysLeft = Math.ceil((info.expire - now) / DAY_SECONDS);
  }

  return {
    used,
    total,
    percent,
    expireDate,
    daysLeft,
    exhausted: (daysLeft !== null && daysLeft < 0) || percent === 100,
    title: info.title,
  };
}

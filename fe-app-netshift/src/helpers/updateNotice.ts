// The "a newer version is available" notice on the dashboard (netshift
// get_update_notice): what the last check found, and whether it is time to look
// again.

export interface UpdateCheck {
  current_version: string;
  latest_version: string;
  status: string;
}

export interface UpdateNotice {
  enabled: boolean;
  stale: boolean;
  checked: number | null;
  netshift: UpdateCheck | null;
  sing_box: UpdateCheck | null;
}

export const EMPTY_UPDATE_NOTICE: UpdateNotice = {
  enabled: false,
  stale: false,
  checked: null,
  netshift: null,
  sing_box: null,
};

function parseCheck(value: unknown): UpdateCheck | null {
  if (!value || typeof value !== 'object') {
    return null;
  }

  const raw = value as Record<string, unknown>;

  if (
    typeof raw.latest_version !== 'string' ||
    typeof raw.current_version !== 'string'
  ) {
    return null;
  }

  return {
    current_version: raw.current_version,
    latest_version: raw.latest_version,
    status: typeof raw.status === 'string' ? raw.status : '',
  };
}

export function parseUpdateNotice(input: unknown): UpdateNotice {
  let data: unknown = input;

  if (typeof input === 'string') {
    try {
      data = JSON.parse(input);
    } catch {
      return EMPTY_UPDATE_NOTICE;
    }
  }

  if (!data || typeof data !== 'object') {
    return EMPTY_UPDATE_NOTICE;
  }

  const raw = data as Record<string, unknown>;

  return {
    enabled: raw.enabled === true,
    stale: raw.stale === true,
    checked: typeof raw.checked === 'number' ? raw.checked : null,
    netshift: parseCheck(raw.netshift),
    sing_box: parseCheck(raw.sing_box),
  };
}

export type UpdateNoticeComponent = 'netshift' | 'sing_box';

export interface UpdateNoticeItem {
  component: UpdateNoticeComponent;
  current: string;
  latest: string;
}

// The components that have a newer version.
export function getOutdatedComponents(
  notice: UpdateNotice,
): UpdateNoticeItem[] {
  const items: UpdateNoticeItem[] = [];

  for (const component of ['netshift', 'sing_box'] as const) {
    const check = notice[component];

    if (check && check.status === 'outdated') {
      items.push({
        component,
        current: check.current_version,
        latest: check.latest_version,
      });
    }
  }

  return items;
}

// A background refresh is worth starting when the notice is on and its answer
// is old (or there is none).
export function shouldRefreshUpdateNotice(notice: UpdateNotice): boolean {
  return notice.enabled && notice.stale;
}

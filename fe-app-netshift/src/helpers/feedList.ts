// The answer of `netshift fetch_feed_list <url>`: the addresses of the subscription
// feeds that a published list names.

export interface FeedListResult {
  ok: boolean;
  urls: string[];
  error?: string;
}

export function parseFeedList(input: unknown): FeedListResult {
  let data: unknown = input;

  if (typeof input === 'string') {
    try {
      data = JSON.parse(input);
    } catch {
      return { ok: false, urls: [], error: '' };
    }
  }

  if (!data || typeof data !== 'object') {
    return { ok: false, urls: [], error: '' };
  }

  const value = data as Record<string, unknown>;

  if (value.ok !== true || !Array.isArray(value.urls)) {
    return {
      ok: false,
      urls: [],
      error: typeof value.error === 'string' ? value.error : '',
    };
  }

  return {
    ok: true,
    urls: value.urls.filter(
      (item): item is string =>
        typeof item === 'string' && /^https?:\/\/\S+$/.test(item),
    ),
  };
}

// The feeds to add: the ones that are not in the list yet, in the order of the list.
export function newFeeds(existing: string[], found: string[]): string[] {
  const known = new Set(existing.map((item) => item.trim()));

  return found.filter((item, index) => {
    if (known.has(item) || found.indexOf(item) !== index) {
      return false;
    }

    return true;
  });
}

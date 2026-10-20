// The DNS speed test (netshift dns_benchmark): how long each upstream needs to
// answer from this router.

export interface DnsBenchmarkResult {
  server: string;
  // Milliseconds; null: no answer, or a server dig cannot ask (doh3, doq).
  ms: number | null;
  // How this server was asked: through the tunnel or from the router itself.
  via: 'tunnel' | 'direct';
}

export function parseDnsBenchmark(input: unknown): DnsBenchmarkResult[] {
  let data: unknown = input;

  if (typeof input === 'string') {
    try {
      data = JSON.parse(input);
    } catch {
      return [];
    }
  }

  const list = (data as { results?: unknown } | null)?.results;

  if (!Array.isArray(list)) {
    return [];
  }

  return list
    .filter((item) => item && typeof item.server === 'string')
    .map((item) => ({
      server: item.server,
      ms: typeof item.ms === 'number' && item.ms >= 0 ? item.ms : null,
      via: item.via === 'tunnel' ? 'tunnel' : 'direct',
    }));
}

// Where the servers were asked from: through the tunnel, from the router itself,
// or both (some servers have their own route).
export function parseDnsBenchmarkVia(
  input: unknown,
): 'tunnel' | 'direct' | 'mixed' {
  let data: unknown = input;

  if (typeof input === 'string') {
    try {
      data = JSON.parse(input);
    } catch {
      return 'direct';
    }
  }

  const via = (data as { via?: unknown } | null)?.via;

  return via === 'tunnel' || via === 'mixed' ? via : 'direct';
}

// Fastest first; servers without a time go last, keeping their order.
export function sortBySpeed(
  results: DnsBenchmarkResult[],
): DnsBenchmarkResult[] {
  return results
    .map((result, index) => ({ result, index }))
    .sort((a, b) => {
      if (a.result.ms === null && b.result.ms === null) {
        return a.index - b.index;
      }

      if (a.result.ms === null) {
        return 1;
      }

      if (b.result.ms === null) {
        return -1;
      }

      return a.result.ms - b.result.ms || a.index - b.index;
    })
    .map((item) => item.result);
}

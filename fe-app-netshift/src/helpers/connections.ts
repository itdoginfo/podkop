// The Connections page: the live connection table of sing-box (netshift
// clash_api get_connections), shaped for display.

export interface Connection {
  id: string;
  network: string;
  type: string;
  source: string;
  host: string;
  destination: string;
  port: string;
  chains: string[];
  rule: string;
  rule_payload: string;
  upload: number;
  download: number;
  start: string;
}

export interface ConnectionsSnapshot {
  downloadTotal: number;
  uploadTotal: number;
  total: number;
  connections: Connection[];
}

export const EMPTY_CONNECTIONS: ConnectionsSnapshot = {
  downloadTotal: 0,
  uploadTotal: 0,
  total: 0,
  connections: [],
};

const text = (value: unknown): string =>
  typeof value === 'string' ? value : value == null ? '' : String(value);

const count = (value: unknown): number =>
  typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;

export function parseConnections(input: unknown): ConnectionsSnapshot {
  let data: unknown = input;

  if (typeof input === 'string') {
    try {
      data = JSON.parse(input);
    } catch {
      return EMPTY_CONNECTIONS;
    }
  }

  if (!data || typeof data !== 'object') {
    return EMPTY_CONNECTIONS;
  }

  const raw = data as Record<string, unknown>;
  const list = Array.isArray(raw.connections) ? raw.connections : [];

  const connections = list
    .filter((item) => item && typeof item === 'object' && item.id)
    .map(
      (item): Connection => ({
        id: text(item.id),
        network: text(item.network),
        type: text(item.type),
        source: text(item.source),
        host: text(item.host),
        destination: text(item.destination),
        port: text(item.port),
        chains: Array.isArray(item.chains) ? item.chains.map(text) : [],
        rule: text(item.rule),
        rule_payload: text(item.rule_payload),
        upload: count(item.upload),
        download: count(item.download),
        start: text(item.start),
      }),
    );

  return {
    downloadTotal: count(raw.downloadTotal),
    uploadTotal: count(raw.uploadTotal),
    total: count(raw.total) || connections.length,
    connections,
  };
}

// "group > node" the way the traffic flows: the backend lists the chain from the
// exit back to the first group.
export function connectionRoute(connection: Connection): string {
  return [...connection.chains].reverse().join(' → ');
}

export function connectionTarget(connection: Connection): string {
  const host = connection.host || connection.destination;

  return connection.port ? `${host}:${connection.port}` : host;
}

export function filterConnections(
  connections: Connection[],
  query: string,
): Connection[] {
  const needle = query.trim().toLowerCase();

  if (!needle) {
    return connections;
  }

  return connections.filter((connection) =>
    [
      connectionTarget(connection),
      connection.destination,
      connection.source,
      connectionRoute(connection),
      connection.rule_payload,
      connection.network,
    ].some((field) => field.toLowerCase().includes(needle)),
  );
}

export type ConnectionSortKey = 'recent' | 'traffic' | 'host';

export function sortConnections(
  connections: Connection[],
  key: ConnectionSortKey,
): Connection[] {
  const copy = [...connections];

  if (key === 'traffic') {
    return copy.sort((a, b) => b.upload + b.download - (a.upload + a.download));
  }

  if (key === 'host') {
    return copy.sort((a, b) =>
      connectionTarget(a).localeCompare(connectionTarget(b)),
    );
  }

  // 'recent': the order of the backend (newest first) is kept
  return copy;
}

// "3 s", "4 min", "2 h": how long ago the connection started. `now` in ms.
export function connectionAge(
  start: string,
  now: number,
): { value: number; unit: 's' | 'min' | 'h' | 'd' } | null {
  const started = Date.parse(start);

  if (Number.isNaN(started)) {
    return null;
  }

  const seconds = Math.max(0, Math.floor((now - started) / 1000));

  if (seconds < 60) {
    return { value: seconds, unit: 's' };
  }

  if (seconds < 3600) {
    return { value: Math.floor(seconds / 60), unit: 'min' };
  }

  if (seconds < 86400) {
    return { value: Math.floor(seconds / 3600), unit: 'h' };
  }

  return { value: Math.floor(seconds / 86400), unit: 'd' };
}

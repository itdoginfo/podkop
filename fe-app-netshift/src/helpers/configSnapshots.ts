// Snapshots of /etc/config/netshift (netshift config_snapshot): the settings the
// service last started with, kept to come back to.

export type SnapshotLabel = 'auto' | 'manual' | 'before-restore';

export interface ConfigSnapshot {
  id: string;
  time: number;
  label: SnapshotLabel;
  size: number;
  // The snapshot equals the configuration in use now.
  current: boolean;
}

const LABELS: SnapshotLabel[] = ['auto', 'manual', 'before-restore'];

export function parseSnapshots(input: unknown): ConfigSnapshot[] {
  let data: unknown = input;

  if (typeof input === 'string') {
    try {
      data = JSON.parse(input);
    } catch {
      return [];
    }
  }

  const list = (data as { snapshots?: unknown } | null)?.snapshots;

  if (!Array.isArray(list)) {
    return [];
  }

  return list
    .filter(
      (item) =>
        item &&
        typeof item.id === 'string' &&
        typeof item.time === 'number' &&
        LABELS.includes(item.label),
    )
    .map((item) => ({
      id: item.id,
      time: item.time,
      label: item.label as SnapshotLabel,
      size: typeof item.size === 'number' ? item.size : 0,
      current: item.current === true,
    }));
}

// "2026-10-06 12:34" in the browser's local time.
export function formatSnapshotTime(time: number): string {
  const date = new Date(time * 1000);
  const pad = (value: number) => String(value).padStart(2, '0');

  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

import { describe, expect, it } from 'vitest';
import { formatSnapshotTime, parseSnapshots } from '../configSnapshots';

describe('parseSnapshots', () => {
  it('reads the backend answer', () => {
    const list = parseSnapshots(
      JSON.stringify({
        snapshots: [
          {
            id: '1790000002-manual',
            time: 1790000002,
            label: 'manual',
            size: 1200,
            current: true,
          },
          {
            id: '1790000001-auto',
            time: 1790000001,
            label: 'auto',
            size: 1100,
            current: false,
          },
        ],
      }),
    );

    expect(list.map((item) => item.id)).toEqual([
      '1790000002-manual',
      '1790000001-auto',
    ]);
    expect(list[0].current).toBe(true);
    expect(list[1].size).toBe(1100);
  });

  it('drops entries it does not understand', () => {
    expect(
      parseSnapshots({
        snapshots: [
          { id: 'x', time: 1, label: 'evil' },
          { id: 5, time: 1, label: 'auto' },
          { id: 'a', label: 'auto' },
          null,
        ],
      }),
    ).toEqual([]);
  });

  it('survives garbage', () => {
    expect(parseSnapshots('Usage: netshift')).toEqual([]);
    expect(parseSnapshots(null)).toEqual([]);
    expect(parseSnapshots({})).toEqual([]);
    expect(parseSnapshots({ snapshots: 'x' })).toEqual([]);
  });
});

describe('formatSnapshotTime', () => {
  it('formats a date and a time with zero padding', () => {
    const time = Math.floor(new Date(2026, 0, 5, 7, 4).getTime() / 1000);

    expect(formatSnapshotTime(time)).toBe('2026-01-05 07:04');
  });
});

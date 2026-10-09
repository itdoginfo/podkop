import { describe, expect, it } from 'vitest';
import {
  connectionAge,
  connectionRoute,
  connectionTarget,
  filterConnections,
  parseConnections,
  sortConnections,
} from '../connections';

const answer = {
  downloadTotal: 5000,
  uploadTotal: 700,
  total: 3,
  connections: [
    {
      id: 'a',
      network: 'tcp',
      type: 'tproxy',
      source: '192.168.1.10:50000',
      host: 'example.com',
      destination: '203.0.113.9',
      port: '443',
      chains: ['main-out', 'Selector'],
      rule: 'RuleSet',
      rule_payload: 'main-ruleset',
      upload: 10,
      download: 2000,
      start: '2026-10-06T10:00:00Z',
    },
    {
      id: 'b',
      network: 'udp',
      type: 'tproxy',
      source: '192.168.1.11:123',
      host: '198.51.100.4',
      destination: '198.51.100.4',
      port: '53',
      chains: ['direct-out'],
      rule: 'final',
      rule_payload: '',
      upload: 1,
      download: 2,
      start: '2026-10-06T10:05:00Z',
    },
    { id: 'c', host: 'a.test', upload: 5000, download: 0 },
  ],
};

describe('parseConnections', () => {
  it('reads the backend answer', () => {
    const parsed = parseConnections(JSON.stringify(answer));

    expect(parsed.total).toBe(3);
    expect(parsed.downloadTotal).toBe(5000);
    expect(parsed.connections.map((c) => c.id)).toEqual(['a', 'b', 'c']);
  });

  it('fills what is missing', () => {
    const [, , third] = parseConnections(answer).connections;

    expect(third.chains).toEqual([]);
    expect(third.port).toBe('');
    expect(third.start).toBe('');
  });

  it('drops entries without an id and survives garbage', () => {
    expect(
      parseConnections({ connections: [{ host: 'x' }, null, 5] }).connections,
    ).toEqual([]);
    expect(parseConnections('Usage: netshift').connections).toEqual([]);
    expect(parseConnections(null).total).toBe(0);
    expect(parseConnections({ downloadTotal: -4 }).downloadTotal).toBe(0);
  });
});

describe('connection text', () => {
  const [a, b] = parseConnections(answer).connections;

  it('shows the route from the first group to the exit', () => {
    expect(connectionRoute(a)).toBe('Selector → main-out');
    expect(connectionRoute(b)).toBe('direct-out');
  });

  it('shows the host and port, or the address', () => {
    expect(connectionTarget(a)).toBe('example.com:443');
    expect(connectionTarget({ ...b, host: '', port: '' })).toBe('198.51.100.4');
  });
});

describe('filterConnections', () => {
  const all = parseConnections(answer).connections;

  it.each([
    ['', 3],
    ['EXAMPLE', 1],
    ['192.168.1.11', 1],
    ['main-ruleset', 1],
    ['direct-out', 1],
    ['udp', 1],
    ['nothing', 0],
  ])('%j -> %i', (query, expected) => {
    expect(filterConnections(all, query)).toHaveLength(expected);
  });
});

describe('sortConnections', () => {
  const all = parseConnections(answer).connections;

  it('keeps the backend order for "recent"', () => {
    expect(sortConnections(all, 'recent').map((c) => c.id)).toEqual([
      'a',
      'b',
      'c',
    ]);
  });

  it('puts the busiest first for "traffic"', () => {
    expect(sortConnections(all, 'traffic').map((c) => c.id)).toEqual([
      'c',
      'a',
      'b',
    ]);
  });

  it('sorts by target for "host"', () => {
    expect(sortConnections(all, 'host').map((c) => c.id)).toEqual([
      'b',
      'c',
      'a',
    ]);
  });

  it('does not change the list it was given', () => {
    const before = all.map((c) => c.id).join();

    sortConnections(all, 'traffic');
    expect(all.map((c) => c.id).join()).toBe(before);
  });
});

describe('connectionAge', () => {
  const now = Date.parse('2026-10-06T12:00:00Z');

  it.each([
    ['2026-10-06T11:59:57Z', 3, 's'],
    ['2026-10-06T11:55:00Z', 5, 'min'],
    ['2026-10-06T09:00:00Z', 3, 'h'],
    ['2026-10-04T12:00:00Z', 2, 'd'],
  ])('%s', (start, value, unit) => {
    expect(connectionAge(start, now)).toEqual({ value, unit });
  });

  it('gives null for a start that is not a date, and never a negative age', () => {
    expect(connectionAge('', now)).toBeNull();
    expect(connectionAge('2026-10-06T12:00:05Z', now)).toEqual({
      value: 0,
      unit: 's',
    });
  });
});

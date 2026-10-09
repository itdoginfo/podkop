import { describe, expect, it } from 'vitest';
import {
  parseDnsBenchmark,
  parseDnsBenchmarkVia,
  sortBySpeed,
} from '../dnsBenchmark';

describe('parseDnsBenchmark', () => {
  it('reads the backend answer', () => {
    expect(
      parseDnsBenchmark(
        JSON.stringify({
          results: [
            { server: 'udp://1.1.1.1', ms: 17 },
            { server: 'doh3://dns.google', ms: null },
          ],
        }),
      ),
    ).toEqual([
      { server: 'udp://1.1.1.1', ms: 17 },
      { server: 'doh3://dns.google', ms: null },
    ]);
  });

  it('survives garbage', () => {
    expect(parseDnsBenchmark('Usage: netshift')).toEqual([]);
    expect(parseDnsBenchmark(null)).toEqual([]);
    expect(parseDnsBenchmark({ results: 'x' })).toEqual([]);
    expect(parseDnsBenchmark({ results: [{ ms: 5 }, null] })).toEqual([]);
  });

  it('turns a strange time into "no answer"', () => {
    expect(
      parseDnsBenchmark({
        results: [
          { server: 'a', ms: -1 },
          { server: 'b', ms: '5' },
        ],
      }),
    ).toEqual([
      { server: 'a', ms: null },
      { server: 'b', ms: null },
    ]);
  });
});

describe('sortBySpeed', () => {
  it('puts the fastest first and the silent last', () => {
    expect(
      sortBySpeed([
        { server: 'slow', ms: 90 },
        { server: 'none', ms: null },
        { server: 'fast', ms: 12 },
        { server: 'none2', ms: null },
      ]).map((item) => item.server),
    ).toEqual(['fast', 'slow', 'none', 'none2']);
  });

  it('keeps the order of equal times', () => {
    expect(
      sortBySpeed([
        { server: 'a', ms: 20 },
        { server: 'b', ms: 20 },
      ]).map((item) => item.server),
    ).toEqual(['a', 'b']);
  });

  it('does not change the list it was given', () => {
    const list = [
      { server: 'b', ms: 30 },
      { server: 'a', ms: 10 },
    ];

    sortBySpeed(list);
    expect(list[0].server).toBe('b');
  });
});

describe('parseDnsBenchmarkVia', () => {
  it('knows where the servers were asked from', () => {
    expect(
      parseDnsBenchmarkVia(JSON.stringify({ via: 'tunnel', results: [] })),
    ).toBe('tunnel');
    expect(parseDnsBenchmarkVia({ via: 'direct', results: [] })).toBe('direct');
  });

  it('says direct for an older backend and for garbage', () => {
    expect(parseDnsBenchmarkVia({ results: [] })).toBe('direct');
    expect(parseDnsBenchmarkVia('Usage: netshift')).toBe('direct');
    expect(parseDnsBenchmarkVia(null)).toBe('direct');
  });
});

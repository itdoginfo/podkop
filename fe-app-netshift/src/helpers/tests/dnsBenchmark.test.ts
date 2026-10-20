import { describe, expect, it } from 'vitest';
import {
  DnsBenchmarkResult,
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
      { server: 'udp://1.1.1.1', ms: 17, via: 'direct' },
      { server: 'doh3://dns.google', ms: null, via: 'direct' },
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
          { server: 'a', ms: -1, via: 'direct' },
          { server: 'b', ms: '5', via: 'direct' },
        ],
      }),
    ).toEqual([
      { server: 'a', ms: null, via: 'direct' },
      { server: 'b', ms: null, via: 'direct' },
    ]);
  });
});

describe('sortBySpeed', () => {
  it('puts the fastest first and the silent last', () => {
    expect(
      sortBySpeed([
        { server: 'slow', ms: 90, via: 'direct' },
        { server: 'none', ms: null, via: 'direct' },
        { server: 'fast', ms: 12, via: 'direct' },
        { server: 'none2', ms: null, via: 'direct' },
      ]).map((item) => item.server),
    ).toEqual(['fast', 'slow', 'none', 'none2']);
  });

  it('keeps the order of equal times', () => {
    expect(
      sortBySpeed([
        { server: 'a', ms: 20, via: 'direct' },
        { server: 'b', ms: 20, via: 'direct' },
      ]).map((item) => item.server),
    ).toEqual(['a', 'b']);
  });

  it('does not change the list it was given', () => {
    const list: DnsBenchmarkResult[] = [
      { server: 'b', ms: 30, via: 'direct' },
      { server: 'a', ms: 10, via: 'direct' },
    ];

    sortBySpeed(list);
    expect(list[0].server).toBe('b');
  });
});

describe('parseDnsBenchmark: route of each server', () => {
  it('says how each server was asked', () => {
    expect(
      parseDnsBenchmark({
        results: [
          { server: 'a', ms: 4, via: 'tunnel' },
          { server: 'b', ms: 9, via: 'direct' },
          { server: 'c', ms: 9 },
        ],
      }).map((item) => item.via),
    ).toEqual(['tunnel', 'direct', 'direct']);
  });
});

describe('parseDnsBenchmarkVia', () => {
  it('knows where the servers were asked from', () => {
    expect(
      parseDnsBenchmarkVia(JSON.stringify({ via: 'tunnel', results: [] })),
    ).toBe('tunnel');
    expect(parseDnsBenchmarkVia({ via: 'direct', results: [] })).toBe('direct');
    expect(parseDnsBenchmarkVia({ via: 'mixed', results: [] })).toBe('mixed');
  });

  it('says direct for an older backend and for garbage', () => {
    expect(parseDnsBenchmarkVia({ results: [] })).toBe('direct');
    expect(parseDnsBenchmarkVia('Usage: netshift')).toBe('direct');
    expect(parseDnsBenchmarkVia(null)).toBe('direct');
  });
});

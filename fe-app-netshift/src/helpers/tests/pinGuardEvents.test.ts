import { describe, expect, it } from 'vitest';
import {
  PIN_GUARD_SHOW_SECONDS,
  parsePinGuardEvents,
  recentPinGuardEvents,
} from '../pinGuardEvents';

const NOW = 1790000000;
const event = (time: number, section = 'main') => ({
  time,
  section,
  from: 'node-a',
  to: 'main-urltest-out',
});

describe('parsePinGuardEvents', () => {
  it('reads the backend answer', () => {
    expect(parsePinGuardEvents(JSON.stringify([event(NOW)]))).toEqual([
      event(NOW),
    ]);
  });

  it('drops entries that are not events', () => {
    expect(
      parsePinGuardEvents([
        event(NOW),
        { time: 'x' },
        null,
        5,
        { section: 's' },
      ]),
    ).toEqual([event(NOW)]);
  });

  it('survives garbage', () => {
    expect(parsePinGuardEvents('Usage: netshift')).toEqual([]);
    expect(parsePinGuardEvents({})).toEqual([]);
    expect(parsePinGuardEvents(null)).toEqual([]);
  });
});

describe('recentPinGuardEvents', () => {
  it('keeps the last day, newest first', () => {
    const list = [
      event(NOW - 3600, 'a'),
      event(NOW - PIN_GUARD_SHOW_SECONDS - 1, 'old'),
      event(NOW - 60, 'b'),
    ];

    expect(recentPinGuardEvents(list, NOW).map((e) => e.section)).toEqual([
      'b',
      'a',
    ]);
  });

  it('is empty when nothing is recent', () => {
    expect(recentPinGuardEvents([event(1)], NOW)).toEqual([]);
    expect(recentPinGuardEvents([], NOW)).toEqual([]);
  });
});

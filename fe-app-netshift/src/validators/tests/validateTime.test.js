import { describe, expect, it } from 'vitest';
import { validateTime } from '../validateTime';

export const validTimes = [
  ['Midnight', '00:00'],
  ['Last minute of the day', '23:59'],
  ['Default daily time', '09:52'],
  ['Night time', '04:30'],
  ['Noon', '12:00'],
  ['Start of the 20s', '20:00'],
];

export const invalidTimes = [
  ['Empty string', ''],
  ['Hour out of range', '24:00'],
  ['Minute out of range', '12:60'],
  ['Single digit hour', '9:15'],
  ['Single digit minute', '09:5'],
  ['No colon', '0930'],
  ['Seconds', '09:15:30'],
  ['Dot separator', '09.15'],
  ['Letters', 'ab:cd'],
  ['Leading space', ' 09:15'],
  ['12-hour suffix', '09:15 PM'],
  ['Negative', '-1:00'],
];

describe('validateTime', () => {
  describe.each(validTimes)('Valid time: %s', (_desc, time) => {
    it(`returns valid=true for "${time}"`, () => {
      expect(validateTime(time).valid).toBe(true);
    });
  });

  describe.each(invalidTimes)('Invalid time: %s', (_desc, time) => {
    it(`returns valid=false for "${time}"`, () => {
      expect(validateTime(time).valid).toBe(false);
    });
  });
});

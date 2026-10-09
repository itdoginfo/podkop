import { describe, expect, it } from 'vitest';
import {
  createLogErrorBatcher,
  logLineMessage,
  summarizeLogErrors,
  type LogErrorBatch,
} from '../summarizeLogErrors';

const line = (time: string, text: string) =>
  `Wed Oct 7 ${time} 2026 user.notice netshift: [error] ${text}`;

describe('logLineMessage', () => {
  it('drops the time and the facility', () => {
    expect(logLineMessage(line('14:34:24', 'Unknown security'))).toBe(
      '[error] Unknown security',
    );
  });

  it('keeps a line that is not in the usual form', () => {
    expect(logLineMessage('plain text')).toBe('plain text');
  });
});

describe('summarizeLogErrors', () => {
  it('counts the same message once, whatever the time', () => {
    const batch = summarizeLogErrors([
      line('14:34:24', 'Unknown security'),
      line('14:34:25', 'Unknown security'),
      line('14:34:26', 'Unknown security'),
    ]);

    expect(batch.shown).toEqual([
      { message: '[error] Unknown security', count: 3 },
    ]);
  });

  it('shows the first messages and counts the rest', () => {
    const lines = ['a', 'b', 'c', 'd', 'e', 'e', 'e'].map((text) =>
      line('14:34:24', text),
    );
    const batch = summarizeLogErrors(lines, 3);

    expect(batch.shown.map((item) => item.message)).toEqual([
      '[error] a',
      '[error] b',
      '[error] c',
    ]);
    expect(batch.hiddenLines).toBe(4);
  });

  it('is empty for no lines', () => {
    expect(summarizeLogErrors([])).toEqual({
      shown: [],
      hiddenLines: 0,
    });
  });

  it('never leaves a fatal message out, whatever came before it', () => {
    const lines = [
      ...['a', 'b', 'c', 'd'].map((text) => line('14:34:24', text)),
      'Wed Oct 7 14:34:25 2026 user.err netshift: [fatal] Sing-box configuration is invalid',
    ];
    const batch = summarizeLogErrors(lines, 3);

    expect(batch.shown[0].message).toContain('[fatal]');
    expect(batch.shown).toHaveLength(3);
    expect(batch.hiddenLines).toBe(2);
  });

  it('shows every fatal message even when there are more than the limit', () => {
    const lines = ['x', 'y', 'z', 'w'].map(
      (text) => `Wed Oct 7 14:34:25 2026 user.err netshift: [fatal] ${text}`,
    );
    const batch = summarizeLogErrors([line('14:34:24', 'a'), ...lines], 3);

    expect(batch.shown).toHaveLength(4);
    expect(batch.shown.every((item) => item.message.includes('[fatal]'))).toBe(
      true,
    );
    expect(batch.hiddenLines).toBe(1);
  });
});

describe('createLogErrorBatcher', () => {
  it('hands over the lines of one go once, and starts again for the next', () => {
    const scheduled: Array<() => void> = [];
    const batches: LogErrorBatch[] = [];
    const batcher = createLogErrorBatcher(
      (batch) => batches.push(batch),
      (callback) => scheduled.push(callback),
    );

    batcher.push(line('14:34:24', 'a'));
    batcher.push(line('14:34:24', 'a'));
    batcher.push(line('14:34:24', 'b'));

    expect(scheduled).toHaveLength(1);
    expect(batches).toHaveLength(0);

    scheduled.shift()?.();

    expect(batches).toHaveLength(1);
    expect(batches[0].shown.map((item) => item.count)).toEqual([2, 1]);

    batcher.push(line('14:34:27', 'c'));
    scheduled.shift()?.();

    expect(batches).toHaveLength(2);
    expect(batches[1].shown).toHaveLength(1);
  });
});

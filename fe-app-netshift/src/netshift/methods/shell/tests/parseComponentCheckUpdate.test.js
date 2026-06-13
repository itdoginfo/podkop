import { describe, expect, it } from 'vitest';
import { parseComponentCheckUpdate } from '../parseComponentCheckUpdate';

describe('parseComponentCheckUpdate', () => {
  it('parses the STABLE check-update JSON', () => {
    const result = parseComponentCheckUpdate(
      JSON.stringify({
        success: true,
        current_version: '1.12.0',
        latest_version: '1.12.9',
        status: 'outdated',
      }),
    );

    expect(result).toEqual({
      success: true,
      current_version: '1.12.0',
      latest_version: '1.12.9',
      status: 'outdated',
      message: undefined,
    });
  });

  it.each(['latest', 'outdated', 'dev', 'not_installed'])(
    'accepts the valid status %s',
    (status) => {
      const result = parseComponentCheckUpdate(
        JSON.stringify({ success: true, status }),
      );

      expect(result.status).toBe(status);
    },
  );

  it('drops an unknown status to undefined', () => {
    const result = parseComponentCheckUpdate(
      JSON.stringify({ success: true, status: 'weird' }),
    );

    expect(result.status).toBeUndefined();
  });

  it('returns success:false with the raw stdout on invalid JSON', () => {
    const result = parseComponentCheckUpdate('not json');

    expect(result).toEqual({ success: false, message: 'not json' });
  });

  it('coerces a missing success to false', () => {
    const result = parseComponentCheckUpdate(JSON.stringify({}));

    expect(result.success).toBe(false);
  });
});

import { describe, expect, it } from 'vitest';
import { describeAutoUpdateState } from '../autoUpdateStatus';

const at = (seconds: number) => `t${seconds}`;

describe('describeAutoUpdateState', () => {
  it('is empty before the first run', () => {
    expect(describeAutoUpdateState({}, at)).toEqual([]);
    expect(describeAutoUpdateState(null, at)).toEqual([]);
    expect(describeAutoUpdateState('broken', at)).toEqual([]);
  });

  it('describes every result of the last run', () => {
    expect(
      describeAutoUpdateState(
        {
          last_run: {
            at: 100,
            trigger: 'boot',
            results: [
              {
                component: 'sing_box',
                result: 'rolled_back',
                from: '1.14.2',
                to: '1.14.4',
                message: 'x',
              },
              {
                component: 'netshift',
                result: 'updated',
                from: '0.9.11',
                to: '0.9.12',
                message: 'x',
              },
            ],
          },
          bad_versions: { sing_box: '1.14.4' },
        },
        at,
      ),
    ).toEqual([
      'Last run: t100 (after boot)',
      'sing-box: 1.14.4 did not work, rolled back to 1.14.2',
      'NetShift: updated 0.9.11 → 0.9.12',
      'Skipped after a rollback: sing-box 1.14.4',
    ]);
  });

  it('shows the latest version and the reason of a skipped or failed run', () => {
    expect(
      describeAutoUpdateState(
        {
          last_run: {
            at: 5,
            trigger: 'scheduled',
            results: [
              {
                component: 'netshift',
                result: 'latest',
                from: '0.9.12',
                to: '0.9.12',
                message: '',
              },
              {
                component: 'all',
                result: 'skipped',
                from: '',
                to: '',
                message: 'NetShift does not work right now',
              },
              {
                component: 'sing_box',
                result: 'skipped',
                from: '1.14.2',
                to: '1.14.4',
                message: 'x',
                reason: 'bad_version',
              },
              {
                component: 'all',
                result: 'skipped',
                from: '',
                to: '',
                message: 'x',
                reason: 'not_working',
              },
            ],
          },
        },
        at,
      ),
    ).toEqual([
      'Last run: t5 (on schedule)',
      'NetShift: the latest version (0.9.12)',
      'NetShift does not work right now',
      'sing-box: skipped: this release was rolled back earlier (1.14.4)',
      'nothing was updated: NetShift did not work before the update',
    ]);
  });
});

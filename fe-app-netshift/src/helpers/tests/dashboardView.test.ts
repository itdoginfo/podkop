import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  loadDashboardViewPrefs,
  saveDashboardViewPrefs,
} from '../dashboardView';

function stubStorage(store: Record<string, string>) {
  vi.stubGlobal('window', {
    localStorage: {
      getItem: (key: string) => store[key] ?? null,
      setItem: (key: string, value: string) => {
        store[key] = value;
      },
    },
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('dashboard view preferences', () => {
  it('defaults to the list without sorting', () => {
    stubStorage({});

    expect(loadDashboardViewPrefs()).toEqual({
      viewMode: 'list',
      sortByPing: false,
    });
  });

  it('remembers what was saved', () => {
    const store: Record<string, string> = {};
    stubStorage(store);

    saveDashboardViewPrefs({ viewMode: 'tiles', sortByPing: true });

    expect(loadDashboardViewPrefs()).toEqual({
      viewMode: 'tiles',
      sortByPing: true,
    });
  });

  it('falls back to the defaults on garbage or a broken storage', () => {
    stubStorage({ netshift_dashboard_view: '{not json' });
    expect(loadDashboardViewPrefs().viewMode).toBe('list');

    vi.stubGlobal('window', {
      localStorage: {
        getItem: () => {
          throw new Error('blocked');
        },
        setItem: () => {
          throw new Error('blocked');
        },
      },
    });
    expect(loadDashboardViewPrefs().viewMode).toBe('list');
    expect(() =>
      saveDashboardViewPrefs({ viewMode: 'tiles', sortByPing: true }),
    ).not.toThrow();
  });
});

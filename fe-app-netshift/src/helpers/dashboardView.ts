export type DashboardViewMode = 'list' | 'tiles';

export interface IDashboardViewPrefs {
  viewMode: DashboardViewMode;
  sortByPing: boolean;
}

const STORAGE_KEY = 'netshift_dashboard_view';

export const DEFAULT_DASHBOARD_VIEW: IDashboardViewPrefs = {
  viewMode: 'list',
  sortByPing: false,
};

// A per-viewer convenience only: any storage failure just gives the defaults.
export function loadDashboardViewPrefs(): IDashboardViewPrefs {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};

    return {
      viewMode: parsed?.viewMode === 'tiles' ? 'tiles' : 'list',
      sortByPing: parsed?.sortByPing === true,
    };
  } catch {
    return { ...DEFAULT_DASHBOARD_VIEW };
  }
}

export function saveDashboardViewPrefs(prefs: IDashboardViewPrefs) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs));
  } catch {
    // storage is not available: the choice just lasts until the page reloads
  }
}

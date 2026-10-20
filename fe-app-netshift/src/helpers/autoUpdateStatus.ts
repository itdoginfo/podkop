// The state the backend keeps about the automatic updates (lib/autoupdate.sh):
// the last run and the releases a rollback marked as bad.
interface AutoUpdateResult {
  component: string;
  result: string;
  from: string;
  to: string;
  message: string;
  reason?: string;
}

export interface AutoUpdateState {
  last_run?: {
    at?: number;
    trigger?: string;
    results?: AutoUpdateResult[];
  };
  bad_versions?: Record<string, string>;
}

const COMPONENT_NAMES: Record<string, () => string> = {
  netshift: () => 'NetShift',
  sing_box: () => 'sing-box',
};

// Why a component was skipped, in the language of the page (the backend's
// message stays for the cases without a code).
const SKIP_REASONS: Record<string, () => string> = {
  stock_core: () =>
    _(
      'not updated: the stock sing-box comes from the firmware packages and cannot be rolled back',
    ),
  dev_build: () => _('not updated: a development build'),
  bad_version: () => _('skipped: this release was rolled back earlier'),
  not_working: () =>
    _('nothing was updated: NetShift did not work before the update'),
  busy: () =>
    _('nothing was updated: the Components manager was installing something'),
};

const TRIGGER_NAMES: Record<string, () => string> = {
  boot: () => _('after boot'),
  scheduled: () => _('on schedule'),
  now: () => _('started by hand'),
};

function describeResult(item: AutoUpdateResult): string {
  const name = COMPONENT_NAMES[item.component]?.() ?? '';
  const prefix = name ? `${name}: ` : '';

  switch (item.result) {
    case 'updated':
      return `${prefix}${_('updated')} ${item.from} → ${item.to}`;
    case 'latest':
      return `${prefix}${_('the latest version')} (${item.from})`;
    case 'rolled_back':
      return `${prefix}${item.to} ${_('did not work, rolled back to')} ${item.from}`;
    default: {
      // skipped and failed: the backend says why
      const reason = SKIP_REASONS[item.reason ?? '']?.();
      const version =
        item.result === 'skipped' && item.to ? ` (${item.to})` : '';

      return reason
        ? `${prefix}${reason}${version}`
        : `${prefix}${item.message}`;
    }
  }
}

// Lines for the settings page: when the last run was, what it did, and which
// releases are skipped after a rollback. Empty when there was no run yet.
export function describeAutoUpdateState(
  state: unknown,
  formatTime: (seconds: number) => string = (seconds) =>
    new Date(seconds * 1000).toLocaleString(),
): string[] {
  if (!state || typeof state !== 'object') {
    return [];
  }

  const { last_run: lastRun, bad_versions: bad } = state as AutoUpdateState;
  const lines: string[] = [];

  if (lastRun?.at) {
    const trigger = TRIGGER_NAMES[lastRun.trigger ?? '']?.();

    lines.push(
      `${_('Last run')}: ${formatTime(lastRun.at)}${trigger ? ` (${trigger})` : ''}`,
    );
    (lastRun.results ?? []).forEach((item) => lines.push(describeResult(item)));
  }

  Object.entries(bad ?? {}).forEach(([component, version]) => {
    if (version) {
      lines.push(
        `${_('Skipped after a rollback')}: ${COMPONENT_NAMES[component]?.() ?? component} ${version}`,
      );
    }
  });

  return lines;
}

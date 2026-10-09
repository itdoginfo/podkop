import { NetShiftShellMethods } from '../../../methods';
import { logger } from '../../../services';
import { renderButton } from '../../../../partials';
import {
  formatSnapshotTime,
  parseSnapshots,
  type ConfigSnapshot,
} from '../../../../helpers/configSnapshots';

// Snapshots of the configuration: the settings the service last started with
// are kept automatically; one can be brought back, followed by a restart.

function labelText(snapshot: ConfigSnapshot) {
  switch (snapshot.label) {
    case 'auto':
      return _('Saved at a successful start');
    case 'manual':
      return _('Saved by hand');
    default:
      return _('Kept before a restore');
  }
}

export function renderSnapshots() {
  const list = E('div', { class: 'pdk_diagnostic-page__snapshots__list' });
  const message = E('div', {
    class: 'pdk_diagnostic-page__snapshots__message',
  });

  function say(text: string) {
    message.textContent = text;
  }

  async function refresh() {
    try {
      const response = await NetShiftShellMethods.listSnapshots();
      const snapshots = response.success ? parseSnapshots(response.data) : [];

      list.replaceChildren(
        ...(snapshots.length === 0
          ? [E('div', {}, _('No snapshots yet'))]
          : snapshots.map((snapshot) =>
              E('div', { class: 'pdk_diagnostic-page__snapshots__row' }, [
                E('div', {}, [
                  E('b', {}, formatSnapshotTime(snapshot.time)),
                  E(
                    'div',
                    { class: 'pdk_diagnostic-page__snapshots__hint' },
                    snapshot.current
                      ? `${labelText(snapshot)} · ${_('same as now')}`
                      : labelText(snapshot),
                  ),
                ]),
                snapshot.current
                  ? E('span', {})
                  : renderButton({
                      text: _('Restore'),
                      onClick: () => void restore(snapshot),
                    }),
              ]),
            )),
      );
    } catch (e) {
      logger.error('[DIAGNOSTIC]', 'snapshots: list failed', e);
    }
  }

  async function restore(snapshot: ConfigSnapshot) {
    if (
      !window.confirm(
        `${_('Bring back the settings of')} ${formatSnapshotTime(snapshot.time)}? ${_('The service will restart.')}`,
      )
    ) {
      return;
    }

    const result = await NetShiftShellMethods.restoreSnapshot(snapshot.id);

    if (!result.success || !result.data || result.data.ok !== true) {
      say(_('The snapshot could not be restored'));

      return;
    }

    say(_('Restored, restarting the service...'));
    await NetShiftShellMethods.restart();
    await refresh();
    say(_('Restored. Reload the page to see the settings.'));
  }

  async function save() {
    const result = await NetShiftShellMethods.saveSnapshot();

    say(
      result.success && result.data?.ok
        ? _('Snapshot saved')
        : _('The snapshot could not be saved'),
    );
    await refresh();
  }

  void refresh();

  return E('div', { class: 'card pdk_diagnostic-page__snapshots' }, [
    E('b', {}, _('Configuration snapshots')),
    E(
      'div',
      { class: 'pdk_diagnostic-page__snapshots__hint' },
      _(
        'The settings are kept every time the service starts successfully (the last ten). A snapshot brings them back after a change that broke the service.',
      ),
    ),
    list,
    message,
    renderButton({
      text: _('Save a snapshot now'),
      onClick: () => void save(),
    }),
  ]);
}

import { NetShiftShellMethods } from '../../../methods';
import { logger } from '../../../services';
import { renderButton } from '../../../../partials';
import { downloadAsTxt } from '../../../../helpers/downloadAsTxt';

// A report for support: versions, settings, the generated config, the state and the logs, with
// the secrets masked on the router. Shown here to be read before it is sent anywhere.

export function renderSupportReport() {
  const text = E('textarea', {
    class: 'cbi-input-textarea pdk_diagnostic-page__support-report__text',
    readOnly: true,
    rows: 12,
    style: 'width:100%;font-family:monospace;display:none',
  }) as HTMLTextAreaElement;
  const message = E('div', {
    class: 'pdk_diagnostic-page__support-report__message',
  });
  const actions = E('div', {
    class: 'pdk_diagnostic-page__support-report__actions',
    style: 'display:none',
  });
  let loading = false;

  function say(value: string) {
    message.textContent = value;
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(text.value);
      say(_('Copied'));
    } catch {
      // not available on a page without HTTPS: the text is selected to be copied by hand
      text.select();
      say(_('Select the text and copy it'));
    }
  }

  async function prepare() {
    if (loading) {
      return;
    }

    loading = true;
    say(_('Preparing the report...'));

    try {
      const response = await NetShiftShellMethods.getSupportReport();
      const report =
        response.success && typeof response.data === 'string'
          ? response.data
          : '';

      if (!report) {
        say(_('The report could not be prepared'));

        return;
      }

      text.value = report;
      text.style.display = 'block';
      actions.style.display = '';
      say(
        _(
          'Read it before you send it: servers are shown as host-N and links, passwords and lists are hidden, but check that nothing of yours is left.',
        ),
      );
    } catch (e) {
      logger.error('[DIAGNOSTIC]', 'support report failed', e);
      say(_('The report could not be prepared'));
    } finally {
      loading = false;
    }
  }

  actions.append(
    renderButton({ text: _('Copy'), onClick: () => void copy() }),
    renderButton({
      text: _('Download'),
      onClick: () => downloadAsTxt(text.value, 'netshift-support-report.txt'),
    }),
  );

  return E('div', { class: 'card pdk_diagnostic-page__support-report' }, [
    E('b', {}, _('Report for support')),
    E(
      'div',
      { class: 'pdk_diagnostic-page__support-report__hint' },
      _(
        'Collects the versions, settings, configuration, state and logs in one text, with passwords, keys, links and server addresses hidden. Send it when you ask for help.',
      ),
    ),
    renderButton({
      text: _('Prepare the report'),
      onClick: () => void prepare(),
    }),
    message,
    text,
    actions,
  ]);
}

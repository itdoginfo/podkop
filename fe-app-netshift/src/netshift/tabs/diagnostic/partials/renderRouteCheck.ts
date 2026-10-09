import { NetShiftShellMethods } from '../../../methods';
import { NetShift } from '../../../types';
import { logger } from '../../../services';
import { renderButton } from '../../../../partials';
import { describeRouteCheck } from '../helpers/describeRouteCheck';

// "Where will a request go": asks the backend to replay the routing rules for a
// domain or an IP address and says which section, DNS server or block applies.

export function renderRouteCheck() {
  const targetInput = E('input', {
    type: 'text',
    class: 'cbi-input-text pdk_diagnostic-page__route-check__input',
    placeholder: 'example.com / 203.0.113.5',
  }) as HTMLInputElement;
  const sourceInput = E('input', {
    type: 'text',
    class: 'cbi-input-text pdk_diagnostic-page__route-check__input',
    placeholder: '192.168.1.10',
  }) as HTMLInputElement;
  const output = E('div', {
    class: 'pdk_diagnostic-page__route-check__result',
  });
  let loading = false;

  async function run() {
    const target = targetInput.value.trim();

    if (!target || loading) {
      return;
    }

    loading = true;
    output.replaceChildren(E('span', {}, _('Checking...')));

    try {
      const response = await NetShiftShellMethods.checkRoute(
        target,
        sourceInput.value.trim(),
      );
      const data = response.success
        ? (response.data as NetShift.RouteCheckResult)
        : { error: _('The check could not be completed') };
      const result =
        typeof data === 'object' && data !== null
          ? data
          : { error: _('The check could not be completed') };

      output.replaceChildren(
        ...describeRouteCheck(result).map((line) => E('div', {}, line)),
      );
    } catch (e) {
      logger.error('[DIAGNOSTIC]', 'route check failed', e);
      output.replaceChildren(
        E('span', {}, _('The check could not be completed')),
      );
    } finally {
      loading = false;
    }
  }

  targetInput.addEventListener('keydown', (event) => {
    if ((event as KeyboardEvent).key === 'Enter') {
      void run();
    }
  });

  const button = renderButton({ text: _('Check'), onClick: () => void run() });

  return E('div', { class: 'card pdk_diagnostic-page__route-check' }, [
    E('b', {}, _('Where will a request go')),
    E(
      'div',
      { class: 'pdk_diagnostic-page__route-check__hint' },
      _(
        'Enter a domain or an IP address to see which section, DNS server or block handles it.',
      ),
    ),
    targetInput,
    E(
      'div',
      { class: 'pdk_diagnostic-page__route-check__hint' },
      _('From the device (optional)'),
    ),
    sourceInput,
    button,
    output,
  ]);
}

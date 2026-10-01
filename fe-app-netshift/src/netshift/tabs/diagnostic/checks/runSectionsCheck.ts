import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { NetShiftShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { getSelectedOutbound } from '../helpers/getSelectedOutbound';
import { getDashboardSections } from '../../../methods/custom/getDashboardSections';
import { IDiagnosticsChecksItem } from '../../../services';

// Delay of one Clash API probe, 0 when the tag did not answer. A reply
// without a delay (an error message, non-JSON output) counts as silent.
async function getDelay(tag: string) {
  const response = await NetShiftShellMethods.getClashApiProxyLatency(tag);

  if (!response.success || response.data?.message) {
    return 0;
  }

  return response.data?.delay || 0;
}

export async function runSectionsCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.OUTBOUNDS;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const sections = await getDashboardSections();

  if (!sections.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Sections checks failed');
  }

  const items = (await Promise.all(
    sections.data.map(async (section) => {
      async function getLatency() {
        if (section.withTagSelect) {
          const selectedOutbound = getSelectedOutbound(section);

          const label =
            selectedOutbound?.type === 'URLTest'
              ? _('Fastest')
              : selectedOutbound?.displayName;
          const prefix = label ? `[${label}] ` : '';

          // One probe through the selected item; for "Fastest" it goes
          // through the server the urltest picked. A group test probes every
          // server of the section and on a large subscription outlasts the
          // call timeout.
          const delay = await getDelay(selectedOutbound?.code ?? section.code);

          if (delay) {
            return {
              success: true,
              latency: `${prefix}${delay}ms`,
            };
          }

          return {
            success: false,
            latency: `${prefix}${_('Not responding')}`,
          };
        }

        const delay = await getDelay(section.code);

        if (delay) {
          return {
            success: true,
            latency: `${delay} ms`,
          };
        }

        return {
          success: false,
          latency: _('Not responding'),
        };
      }

      const { latency, success } = await getLatency();

      return {
        state: success ? 'success' : 'error',
        key: section.displayName,
        value: latency,
      };
    }),
  )) as Array<IDiagnosticsChecksItem>;

  const allGood = items.every((item) => item.state === 'success');

  const atLeastOneGood = items.some((item) => item.state === 'success');

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items,
  });

  if (!atLeastOneGood) {
    throw new Error('Sections checks failed');
  }
}

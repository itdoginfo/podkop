import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { NetShiftShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { getSelectedOutbound } from '../helpers/getSelectedOutbound';
import { getDashboardSections } from '../../../methods/custom/getDashboardSections';
import { IDiagnosticsChecksItem } from '../../../services';

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
          const latencyProxy =
            await NetShiftShellMethods.getClashApiProxyLatency(
              selectedOutbound?.code ?? section.code,
            );

          const delay =
            latencyProxy.success &&
            !latencyProxy.data.message &&
            latencyProxy.data.delay;

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

        const latencyProxy = await NetShiftShellMethods.getClashApiProxyLatency(
          section.code,
        );

        const success = latencyProxy.success && !latencyProxy.data.message;

        if (success) {
          return {
            success: true,
            latency: `${latencyProxy.data.delay} ms`,
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

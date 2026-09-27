import { NetShift } from '../../../types';

// Per-subscription blocks move their nodes out of `outbounds` into
// `subgroups`, so the selected item may live in a subgroup.
export function getSelectedOutbound(
  section: NetShift.OutboundGroup,
): NetShift.Outbound | undefined {
  return [
    ...section.outbounds,
    ...(section.subgroups ?? []).flatMap((subgroup) => subgroup.outbounds),
  ].find((item) => item.selected);
}

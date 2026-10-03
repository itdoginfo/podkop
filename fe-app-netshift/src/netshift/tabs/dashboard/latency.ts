import { NetShift } from '../../types';

const GROUP_TYPES = ['urltest', 'selector'];

// A group entry (urltest/selector), not a server.
export function isGroup(outbound: NetShift.Outbound) {
  return GROUP_TYPES.includes(outbound.type.toLowerCase());
}

function getAllOutbounds(section: NetShift.OutboundGroup) {
  return [
    ...section.outbounds,
    ...(section.subgroups ?? []).flatMap((subgroup) => subgroup.outbounds),
  ];
}

function unique(codes: string[]) {
  return [...new Set(codes.filter(Boolean))];
}

// What "Test latency" of a section measures. `probe` are servers tested one
// by one, so each card updates as soon as its answer arrives. `groups` are
// "Fastest" cards: their delay is the one of the server the urltest picked,
// known only from the refresh after all probes.
export function getLatencyTargets(section: NetShift.OutboundGroup): {
  probe: string[];
  groups: string[];
} {
  if (!section.withTagSelect) {
    return { probe: unique([section.outbounds[0]?.code ?? '']), groups: [] };
  }

  const outbounds = getAllOutbounds(section);

  return {
    probe: unique(
      outbounds.filter((item) => !isGroup(item)).map((item) => item.code),
    ),
    groups: unique(outbounds.filter(isGroup).map((item) => item.code)),
  };
}

export function setOutboundLatency(
  sections: NetShift.OutboundGroup[],
  code: string,
  latency: number,
): NetShift.OutboundGroup[] {
  const update = (outbounds: NetShift.Outbound[]) =>
    outbounds.map((outbound) =>
      outbound.code === code ? { ...outbound, latency } : outbound,
    );

  return sections.map((section) => ({
    ...section,
    outbounds: update(section.outbounds),
    ...(section.subgroups
      ? {
          subgroups: section.subgroups.map((subgroup) => ({
            ...subgroup,
            outbounds: update(subgroup.outbounds),
          })),
        }
      : {}),
  }));
}

// Runs `worker` over `items` with at most `limit` calls in flight.
export async function runWithConcurrency<T>(
  items: T[],
  limit: number,
  worker: (item: T) => Promise<void>,
): Promise<void> {
  const queue = [...items];

  async function next(): Promise<void> {
    const item = queue.shift();

    if (item === undefined) {
      return;
    }

    await worker(item);

    return next();
  }

  await Promise.all(
    Array.from({ length: Math.min(limit, queue.length) }, () => next()),
  );
}

import { describe, expect, it } from 'vitest';
import { sortOutboundsByLatency } from '../sortOutbounds';
import type { NetShift } from '../../../types';

function outbound(code: string, latency: number, type = 'VLESS') {
  return {
    code,
    displayName: code,
    latency,
    type,
    selected: false,
  } as NetShift.Outbound;
}

const codes = (items: NetShift.Outbound[]) => items.map((item) => item.code);

describe('sortOutboundsByLatency', () => {
  it('puts the fastest first', () => {
    const sorted = sortOutboundsByLatency([
      outbound('a', 300),
      outbound('b', 120),
      outbound('c', 200),
    ]);

    expect(codes(sorted)).toEqual(['b', 'c', 'a']);
  });

  it('puts servers without a measurement last, in their order', () => {
    const sorted = sortOutboundsByLatency([
      outbound('a', 0),
      outbound('b', 500),
      outbound('c', 0),
      outbound('d', 90),
    ]);

    expect(codes(sorted)).toEqual(['d', 'b', 'a', 'c']);
  });

  it('keeps the order of equal delays', () => {
    const sorted = sortOutboundsByLatency([
      outbound('a', 100),
      outbound('b', 100),
      outbound('c', 100),
    ]);

    expect(codes(sorted)).toEqual(['a', 'b', 'c']);
  });

  it('keeps group entries such as "Fastest" in front', () => {
    const sorted = sortOutboundsByLatency([
      outbound('a', 400),
      outbound('fastest', 50, 'URLTest'),
      outbound('b', 100),
    ]);

    expect(codes(sorted)).toEqual(['fastest', 'b', 'a']);
  });

  it('does not change the input', () => {
    const input = [outbound('a', 300), outbound('b', 100)];

    sortOutboundsByLatency(input);

    expect(codes(input)).toEqual(['a', 'b']);
  });
});

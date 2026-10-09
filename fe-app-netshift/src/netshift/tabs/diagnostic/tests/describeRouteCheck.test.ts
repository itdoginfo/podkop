import { describe, expect, it } from 'vitest';
import { describeRouteCheck } from '../helpers/describeRouteCheck';

describe('describeRouteCheck', () => {
  it('names the section', () => {
    expect(
      describeRouteCheck({
        verdict: 'section',
        section: 'main',
        rule_set: 'main-user-domains-ruleset',
        dns: { server: 'fakeip-server', verdict: 'rule' },
      }),
    ).toEqual([
      'Goes through the section: main',
      'Matched list: main-user-domains-ruleset',
      'DNS: answered with a FakeIP address, the traffic enters the tunnel path',
    ]);
  });

  it('says so when the global proxy takes everything else', () => {
    expect(
      describeRouteCheck({
        verdict: 'section',
        section: 'main',
        by_default: true,
        dns: { server: 'dns-server', verdict: 'final' },
      })[0],
    ).toBe('Matches no list, goes through the global proxy section: main');
  });

  it('reports a direct path and a block', () => {
    expect(describeRouteCheck({ verdict: 'direct' })[0]).toBe(
      'Goes directly, not through any section',
    );
    expect(describeRouteCheck({ verdict: 'blocked' })[0]).toBe(
      'Blocked by a rule',
    );
  });

  it('shows a DNS section server and a blocked query', () => {
    expect(
      describeRouteCheck({
        verdict: 'direct',
        dns: { server: 'dns-section-corp', verdict: 'rule' },
      }),
    ).toContain('DNS server: dns-section-corp');
    expect(
      describeRouteCheck({
        verdict: 'blocked',
        dns: { server: null, verdict: 'blocked' },
      }),
    ).toContain('The DNS query is blocked');
  });

  it('warns that the answer may be incomplete', () => {
    expect(
      describeRouteCheck({ verdict: 'direct', incomplete: true }).length,
    ).toBe(2);
  });

  it('passes an error through', () => {
    expect(describeRouteCheck({ error: 'empty target' })).toEqual([
      'empty target',
    ]);
  });
});

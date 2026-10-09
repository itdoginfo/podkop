import { NetShift } from '../../../types';

// The lines shown under the route check form for one backend answer.
export function describeRouteCheck(
  result: NetShift.RouteCheckResult,
): string[] {
  if (result.error) {
    return [result.error];
  }

  const lines: string[] = [];

  if (result.verdict === 'section') {
    lines.push(
      `${
        result.by_default
          ? _('Matches no list, goes through the global proxy section')
          : _('Goes through the section')
      }: ${result.section ?? result.outbound ?? '?'}`,
    );
  } else if (result.verdict === 'blocked') {
    lines.push(_('Blocked by a rule'));
  } else {
    lines.push(_('Goes directly, not through any section'));
  }

  if (result.rule_set) {
    lines.push(`${_('Matched list')}: ${result.rule_set}`);
  }

  if (result.dns) {
    if (result.dns.verdict === 'blocked') {
      lines.push(_('The DNS query is blocked'));
    } else if (result.dns.server === 'fakeip-server') {
      lines.push(
        _(
          'DNS: answered with a FakeIP address, the traffic enters the tunnel path',
        ),
      );
    } else if (result.dns.server) {
      lines.push(`${_('DNS server')}: ${result.dns.server}`);
    }
  }

  if (result.incomplete) {
    lines.push(
      _(
        'Some rules depend on the client address, traffic type or lists that are not available here and were skipped. Enter the address of the device for a precise answer.',
      ),
    );
  }

  return lines;
}

import { describe, expect, it } from 'vitest';
import { tokenizeInline } from '../changelog';

describe('tokenizeInline', () => {
  it('turns a Markdown link into a link token', () => {
    expect(
      tokenizeInline(
        'Build of [cergo666/netshift](https://github.com/cergo666/netshift) on top',
      ),
    ).toEqual([
      { kind: 'text', text: 'Build of ' },
      {
        kind: 'link',
        text: 'cergo666/netshift',
        href: 'https://github.com/cergo666/netshift',
      },
      { kind: 'text', text: ' on top' },
    ]);
  });

  it('handles bold and code', () => {
    expect(tokenizeInline('**DNS** and `dns_hijack` (#118)')).toEqual([
      { kind: 'bold', text: 'DNS' },
      { kind: 'text', text: ' and ' },
      { kind: 'code', text: 'dns_hijack' },
      { kind: 'text', text: ' (#118)' },
    ]);
  });

  it('does not make links of other schemes', () => {
    expect(tokenizeInline('[x](javascript:alert(1))')).toEqual([
      { kind: 'text', text: '[x](javascript:alert(1))' },
    ]);
  });

  it('leaves plain text alone', () => {
    expect(tokenizeInline('plain')).toEqual([{ kind: 'text', text: 'plain' }]);
  });
});

import { describe, expect, it } from 'vitest';
import { splitHostPort } from '../splitHostPort';

const cases = [
  ['IPv4 with port', '127.0.0.1:443', '127.0.0.1', '443'],
  ['Domain with port', 'example.com:8080', 'example.com', '8080'],
  ['IPv6 with port', '[2001:db8::1]:443', '2001:db8::1', '443'],
  [
    'Full IPv6 with port',
    '[2001:0db8:0000:0000:0000:0000:0000:0001]:443',
    '2001:0db8:0000:0000:0000:0000:0000:0001',
    '443',
  ],
  ['IPv6 loopback with port', '[::1]:1080', '::1', '1080'],
  [
    'IPv4-mapped IPv6 with port',
    '[::ffff:127.0.0.1]:443',
    '::ffff:127.0.0.1',
    '443',
  ],
  ['IPv6 without port', '[2001:db8::1]', '2001:db8::1', undefined],
  ['IPv4 without port', '127.0.0.1', '127.0.0.1', undefined],
  ['Domain without port', 'example.com', 'example.com', undefined],
  [
    'IPv6 with port and trailing query',
    '[2001:db8::1]:443?type=tcp',
    '2001:db8::1',
    '443?type=tcp',
  ],
];

describe('splitHostPort', () => {
  describe.each(cases)('%s', (_desc, input, expectedHost, expectedPort) => {
    it(`splits "${input}" into host and port`, () => {
      expect(splitHostPort(input)).toEqual([expectedHost, expectedPort]);
    });
  });

  it('keeps the whole string as host when the bracket is unclosed', () => {
    expect(splitHostPort('[2001:db8::1')).toEqual(['[2001', 'db8']);
  });
});

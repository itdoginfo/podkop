import { describe, expect, it } from 'vitest';
import {
  isNetShiftUnconfigured,
  sectionHasConnection,
} from '../sectionHasConnection';

const section = (fields: Record<string, unknown>) => ({
  '.type': 'section',
  '.name': 'main',
  ...fields,
});

describe('sectionHasConnection', () => {
  it('is false for the default section of a fresh install', () => {
    expect(
      sectionHasConnection(
        section({
          connection_type: 'proxy',
          proxy_config_type: 'url',
          proxy_string: '',
        }),
      ),
    ).toBe(false);
  });

  it('reads the option of each proxy type', () => {
    const cases: Array<[string, string, unknown]> = [
      ['url', 'proxy_string', 'vless://u@h:443'],
      ['selector', 'selector_proxy_links', ['vless://u@h:443']],
      ['urltest', 'urltest_proxy_links', ['vless://u@h:443']],
      ['selector_text', 'selector_proxy_links_text', 'vless://u@h:443'],
      ['urltest_text', 'urltest_proxy_links_text', 'vless://u@h:443'],
      ['outbound', 'outbound_json', '{"type":"direct"}'],
      ['subscription', 'subscription_url', ['https://sub.example/x']],
    ];

    cases.forEach(([type, option, value]) => {
      expect(
        sectionHasConnection(
          section({
            connection_type: 'proxy',
            proxy_config_type: type,
            [option]: value,
          }),
        ),
      ).toBe(true);
      expect(
        sectionHasConnection(
          section({ connection_type: 'proxy', proxy_config_type: type }),
        ),
      ).toBe(false);
    });
  });

  it('takes an empty proxy type for a link, like the backend', () => {
    expect(
      sectionHasConnection(
        section({ connection_type: 'proxy', proxy_string: 'ss://x@h:1' }),
      ),
    ).toBe(true);
  });

  it('does not count a link of another proxy type', () => {
    expect(
      sectionHasConnection(
        section({
          connection_type: 'proxy',
          proxy_config_type: 'subscription',
          proxy_string: 'vless://u@h:443',
        }),
      ),
    ).toBe(false);
  });

  it('counts a scalar subscription_url and ignores empty list items', () => {
    expect(
      sectionHasConnection(
        section({
          connection_type: 'proxy',
          proxy_config_type: 'subscription',
          subscription_url: 'https://sub.example/x',
        }),
      ),
    ).toBe(true);
    expect(
      sectionHasConnection(
        section({
          connection_type: 'proxy',
          proxy_config_type: 'subscription',
          subscription_url: [''],
        }),
      ),
    ).toBe(false);
  });

  it('needs an interface for a VPN section', () => {
    expect(
      sectionHasConnection(
        section({ connection_type: 'vpn', interface: 'wg0' }),
      ),
    ).toBe(true);
    expect(sectionHasConnection(section({ connection_type: 'vpn' }))).toBe(
      false,
    );
  });

  it('ignores disabled sections, block/exclusion/dns sections and settings', () => {
    expect(
      sectionHasConnection(
        section({
          connection_type: 'proxy',
          proxy_string: 'vless://u@h:443',
          disabled: '1',
        }),
      ),
    ).toBe(false);
    ['block', 'exclusion', 'dns'].forEach((type) => {
      expect(sectionHasConnection(section({ connection_type: type }))).toBe(
        false,
      );
    });
    expect(
      sectionHasConnection({
        '.type': 'settings',
        '.name': 'settings',
        proxy_string: 'x',
      }),
    ).toBe(false);
  });
});

describe('isNetShiftUnconfigured', () => {
  it('is true when no section has a connection', () => {
    expect(
      isNetShiftUnconfigured([
        { '.type': 'settings', '.name': 'settings' },
        section({ connection_type: 'proxy', proxy_string: '' }),
        section({ connection_type: 'block' }),
      ]),
    ).toBe(true);
  });

  it('is false as soon as one section has one', () => {
    expect(
      isNetShiftUnconfigured([
        section({ connection_type: 'proxy', proxy_string: '' }),
        section({ connection_type: 'vpn', interface: 'wg0' }),
      ]),
    ).toBe(false);
  });
});

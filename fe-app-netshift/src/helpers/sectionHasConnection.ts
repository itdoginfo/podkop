// The option that holds the connection of each proxy_config_type: the same
// options the backend reads in section_has_configured_outbound.
const PROXY_CONNECTION_OPTION: Record<string, string> = {
  url: 'proxy_string',
  selector: 'selector_proxy_links',
  urltest: 'urltest_proxy_links',
  selector_text: 'selector_proxy_links_text',
  urltest_text: 'urltest_proxy_links_text',
  outbound: 'outbound_json',
  subscription: 'subscription_url',
};

function hasValue(value: unknown): boolean {
  if (Array.isArray(value)) {
    return value.some(hasValue);
  }

  return typeof value === 'string' && value.length > 0;
}

// True when the section gives sing-box something to connect through: a link,
// a subscription, an outbound or, for a VPN section, an interface. The backend
// refuses to start while no enabled section has one.
export function sectionHasConnection(section: Record<string, unknown>) {
  if (section['.type'] !== 'section' || section.disabled === '1') {
    return false;
  }

  if (section.connection_type === 'vpn') {
    return hasValue(section.interface);
  }

  if (section.connection_type !== 'proxy') {
    return false;
  }

  // An empty proxy_config_type reads as 'url' in the backend too.
  const option =
    PROXY_CONNECTION_OPTION[String(section.proxy_config_type || 'url')];

  return option ? hasValue(section[option]) : false;
}

// A fresh install: the default section has no link yet, so NetShift does not
// start, and the dashboard says what to do instead of "unavailable".
export function isNetShiftUnconfigured(sections: Record<string, unknown>[]) {
  return !sections.some(sectionHasConnection);
}

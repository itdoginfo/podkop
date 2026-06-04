"use strict";
"require form";
"require baseclass";
"require ui";
"require uci";
"require tools.widgets as widgets";
"require view.podkop.main as main";

function getCbiWidget(section_id, option, event) {
  const sectionName = typeof section_id === "string" ? section_id : "";
  const candidates = [
    `widget.cbid.podkop.${sectionName}.${option}`,
    `cbid.podkop.${sectionName}.${option}`,
  ];

  for (const id of candidates) {
    if (!sectionName) {
      continue;
    }

    const element = document.getElementById(id);
    if (element) {
      return element;
    }
  }

  const selectors = sectionName
    ? [
        `[name="cbid.podkop.${sectionName}.${option}"]`,
        `[id$=".${sectionName}.${option}"]`,
        `[name$=".${sectionName}.${option}"]`,
      ]
    : [];

  for (const selector of selectors) {
    const element = document.querySelector(selector);
    if (element) {
      return element;
    }
  }

  const sectionElement = event?.target?.closest?.(".cbi-section");
  return (
    sectionElement?.querySelector(`[id$=".${option}"]`) ||
    sectionElement?.querySelector(`[name$=".${option}"]`) ||
    document.querySelector(`[id$=".${option}"]`) ||
    document.querySelector(`[name$=".${option}"]`)
  );
}

function getWidgetControl(element) {
  if (!element) {
    return null;
  }

  if (element.matches?.("input, textarea, select")) {
    return element;
  }

  return element.querySelector?.("input, textarea, select") || null;
}

function getWidgetValue(element) {
  return getWidgetControl(element)?.value?.trim?.() || "";
}

function getFormOptionValue(optionContext, section_id, option) {
  if (optionContext?.option === option) {
    return optionContext?.formvalue?.(section_id)?.trim?.() || "";
  }

  const optionItem = optionContext?.map?.lookupOption?.(
    option,
    section_id,
  )?.[0];
  return optionItem?.formvalue?.(section_id)?.trim?.() || "";
}

function getSubscriptionProxyDisplayName(item) {
  return (
    main.getProxyUrlName(item.url) ||
    item.name ||
    _("Server %s").format(item.id)
  );
}

function getSubscriptionServerFlag(displayName) {
  return displayName.match(/[\u{1f1e6}-\u{1f1ff}]{2}/u)?.[0] || "🌐";
}

function getSubscriptionServerTitle(displayName) {
  return displayName
    .replace(/^.*?[\u{1f1e6}-\u{1f1ff}]{2}\s*/u, "")
    .replace(/^pulsr\.\s*/i, "")
    .trim();
}

function getSubscriptionServerSubtitle(item) {
  try {
    const url = new URL(item.url);
    return `${url.hostname}:${url.port || ""}`.replace(/:$/, "");
  } catch (_e) {
    return "";
  }
}

function getSubscriptionServersCacheKey(section_id, subscriptionUrl) {
  return `podkop.subscriptionServers.${section_id}.${subscriptionUrl}`;
}

function getSubscriptionSelectedCacheKey(section_id, subscriptionUrl) {
  return `podkop.subscriptionSelected.${section_id}.${subscriptionUrl}`;
}

function getCachedSubscriptionServers(section_id, subscriptionUrl) {
  if (!subscriptionUrl) {
    return [];
  }

  try {
    const cached = sessionStorage.getItem(
      getSubscriptionServersCacheKey(section_id, subscriptionUrl),
    );
    const parsed = cached ? JSON.parse(cached) : [];

    return Array.isArray(parsed) ? parsed : [];
  } catch (_e) {
    return [];
  }
}

function getCachedSubscriptionSelected(section_id, subscriptionUrl) {
  if (!subscriptionUrl) {
    return "";
  }

  try {
    return (
      sessionStorage.getItem(
        getSubscriptionSelectedCacheKey(section_id, subscriptionUrl),
      ) || ""
    );
  } catch (_e) {
    return "";
  }
}

function setCachedSubscriptionSelected(section_id, subscriptionUrl, url) {
  if (!subscriptionUrl || !url) {
    return;
  }

  try {
    sessionStorage.setItem(
      getSubscriptionSelectedCacheKey(section_id, subscriptionUrl),
      url,
    );
  } catch (_e) {
    // Best effort cache only.
  }
}

function setCachedSubscriptionServers(section_id, subscriptionUrl, servers) {
  if (!subscriptionUrl) {
    return;
  }

  try {
    sessionStorage.setItem(
      getSubscriptionServersCacheKey(section_id, subscriptionUrl),
      JSON.stringify(servers),
    );
  } catch (_e) {
    // Best effort cache only.
  }
}

function setSubscriptionServerValue(root, section_id, url) {
  if (!root) {
    return;
  }

  const subscriptionUrl = root.getAttribute("data-subscription-url") || "";
  root.setAttribute("data-selected-url", url);
  setCachedSubscriptionSelected(section_id, subscriptionUrl, url);

  const input =
    root.querySelector(`[id$=".${section_id}.subscription_proxy_link"]`) ||
    root.querySelector(`[name$=".${section_id}.subscription_proxy_link"]`) ||
    root.querySelector(`[id$=".subscription_proxy_link"]`) ||
    root.querySelector(`[name$=".subscription_proxy_link"]`);

  if (input) {
    input.value = url;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  try {
    uci.set("podkop", section_id, "subscription_proxy_link", url);
  } catch (_e) {
    // The hidden input still carries the value for Save & Apply.
  }

  root.querySelectorAll(".pdk-subscription-server-card").forEach((card) => {
    const selected = card.getAttribute("data-url") === url;
    card.style.borderColor = selected ? "#ff7a59" : "rgba(255,255,255,.12)";
    card.style.background = selected ? "rgba(255,122,89,.14)" : "#242522";
    card.querySelector(".pdk-subscription-server-card__check").textContent =
      selected ? "✓" : "";
  });
}

function renderSubscriptionServerCards(section_id, servers, selectedUrl) {
  if (!servers.length) {
    return [
      E(
        "div",
        {
          style:
            "padding: 14px; border: 1px dashed rgba(255,255,255,.18); border-radius: 12px; color: #aaa;",
        },
        _("Load servers from the subscription URL"),
      ),
    ];
  }

  return servers.map((item) => {
    const displayName = getSubscriptionProxyDisplayName(item);
    const title = getSubscriptionServerTitle(displayName) || displayName;
    const subtitle = getSubscriptionServerSubtitle(item);
    const selected = item.url === selectedUrl;

    return E(
      "button",
      {
        type: "button",
        class: "pdk-subscription-server-card",
        "data-url": item.url,
        style: [
          "display: grid",
          "grid-template-columns: 34px minmax(0, 1fr) 22px",
          "gap: 10px",
          "align-items: center",
          "width: 100%",
          "height: 58px",
          "min-height: 58px",
          "flex: 0 0 58px",
          "padding: 10px 12px",
          "margin: 0",
          "border-radius: 12px",
          `border: 1px solid ${selected ? "#ff7a59" : "rgba(255,255,255,.12)"}`,
          `background: ${selected ? "rgba(255,122,89,.14)" : "#242522"}`,
          "color: inherit",
          "text-align: left",
          "cursor: pointer",
        ].join("; "),
        click: (event) => {
          event.preventDefault();
          setSubscriptionServerValue(
            event.currentTarget.closest(".pdk-subscription-server-picker"),
            section_id,
            item.url,
          );
        },
      },
      [
        E("span", { style: "font-size: 24px; line-height: 1" }, [
          getSubscriptionServerFlag(displayName),
        ]),
        E("span", { style: "min-width: 0" }, [
          E(
            "span",
            {
              style:
                "display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600;",
            },
            title,
          ),
          E(
            "span",
            {
              style:
                "display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; opacity: .65; font-size: 12px; margin-top: 2px;",
            },
            subtitle,
          ),
        ]),
        E(
          "span",
          {
            class: "pdk-subscription-server-card__check",
            style:
              "display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; border-radius: 50%; background: rgba(255,122,89,.22); color: #ffb199; font-weight: 700;",
          },
          selected ? "✓" : "",
        ),
      ],
    );
  });
}

async function loadSubscriptionServers(optionContext, section_id, event) {
  event?.preventDefault?.();
  event?.stopPropagation?.();

  const subscriptionUrlElement = getCbiWidget(
    section_id,
    "subscription_url",
    event,
  );
  const subscriptionProxyLinkElement = getCbiWidget(
    section_id,
    "subscription_proxy_link",
    event,
  );
  const subscriptionProxyLinkControl = getWidgetControl(
    subscriptionProxyLinkElement,
  );
  const picker = document.getElementById(
    `pdk-subscription-server-picker-${section_id}`,
  );
  const cardsContainer = document.getElementById(
    `pdk-subscription-server-cards-${section_id}`,
  );
  const subscriptionUrl =
    getFormOptionValue(optionContext, section_id, "subscription_url") ||
    getWidgetValue(subscriptionUrlElement);
  const currentValue =
    picker?.getAttribute("data-selected-url") ||
    getCachedSubscriptionSelected(section_id, subscriptionUrl) ||
    subscriptionProxyLinkControl?.value ||
    uci.get("podkop", section_id, "subscription_proxy_link") ||
    "";

  if (!subscriptionUrl) {
    ui.addNotification(
      null,
      E("p", {}, _("Subscription URL is required")),
      "error",
    );
    return;
  }

  const validation = main.validateUrl(subscriptionUrl);

  if (!validation.valid) {
    ui.addNotification(null, E("p", {}, validation.message), "error");
    return;
  }

  const response =
    await main.PodkopShellMethods.getSubscriptionOutbounds(subscriptionUrl);

  if (
    !response.success ||
    !Array.isArray(response.data) ||
    !response.data.length
  ) {
    ui.addNotification(
      null,
      E("p", {}, _("No supported proxy links were found in subscription")),
      "error",
    );
    return;
  }

  if (!subscriptionProxyLinkControl || !picker || !cardsContainer) {
    ui.addNotification(
      null,
      E("p", {}, _("Subscription server selector is not available")),
      "error",
    );
    return;
  }

  setCachedSubscriptionServers(section_id, subscriptionUrl, response.data);
  const selectedUrl = response.data.some((item) => item.url === currentValue)
    ? currentValue
    : response.data[0].url;
  picker.setAttribute("data-subscription-url", subscriptionUrl);
  subscriptionProxyLinkControl.value = selectedUrl;
  cardsContainer.replaceChildren(
    ...renderSubscriptionServerCards(section_id, response.data, selectedUrl),
  );
  setSubscriptionServerValue(picker, section_id, selectedUrl);

  ui.addNotification(
    null,
    E("p", {}, _("Subscription servers loaded successfully")),
  );
}

function createSectionContent(section) {
  let o = section.option(
    form.ListValue,
    "connection_type",
    _("Connection Type"),
    _("Select between VPN and Proxy connection methods for traffic routing"),
  );
  o.value("proxy", "Proxy");
  o.value("vpn", "VPN");
  o.value("block", "Block");
  o.value("exclusion", "Exclusion");

  o = section.option(
    form.ListValue,
    "proxy_config_type",
    _("Configuration Type"),
    _("Select how to configure the proxy"),
  );
  o.value("url", _("Connection URL"));
  o.value("selector", _("Selector"));
  o.value("urltest", _("URLTest"));
  o.value("subscription", _("Sub Link"));
  o.value("outbound", _("Outbound Config"));
  o.default = "url";
  o.depends("connection_type", "proxy");

  o = section.option(
    form.TextValue,
    "proxy_string",
    _("Proxy Configuration URL"),
    _("vless://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links"),
  );
  o.depends("proxy_config_type", "url");
  o.rows = 5;
  // Enable soft wrapping for multi-line proxy URLs (e.g., for URLTest proxy links)
  o.wrap = "soft";
  // Render as a textarea to allow multiple proxy URLs/configs
  o.textarea = true;
  o.rmempty = false;
  o.sectionDescriptions = new Map();
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.Value,
    "subscription_url",
    _("Subscription URL"),
    _("HTTP/HTTPS subscription link from a VPN service"),
  );
  o.depends("proxy_config_type", "subscription");
  o.rmempty = false;
  const renderSubscriptionUrlWidget = o.renderWidget;
  o.renderWidget = function (section_id, option_index, cfgvalue) {
    const urlWidget = renderSubscriptionUrlWidget.apply(this, [
      section_id,
      option_index,
      cfgvalue,
    ]);

    return E("div", { style: "display: flex; gap: 8px; align-items: center" }, [
      E("div", { style: "flex: 1 1 auto" }, urlWidget),
      E(
        "button",
        {
          type: "button",
          class: "cbi-button cbi-button-apply",
          style: "white-space: nowrap",
          click: (event) => loadSubscriptionServers(this, section_id, event),
        },
        _("Load Servers"),
      ),
    ]);
  };
  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.Value,
    "subscription_proxy_link",
    _("Subscription Server"),
    _("Select a server loaded from the subscription."),
  );
  o.depends("proxy_config_type", "subscription");
  o.rmempty = false;
  o.subscriptionServerLists = new Map();
  o.load = async function (section_id) {
    const selectedProxyLink = uci.get(
      "podkop",
      section_id,
      "subscription_proxy_link",
    );
    const subscriptionUrl = uci.get("podkop", section_id, "subscription_url");
    const cachedServers = getCachedSubscriptionServers(
      section_id,
      subscriptionUrl,
    );

    const servers = cachedServers.length
      ? cachedServers
      : selectedProxyLink
        ? [{ id: 1, url: selectedProxyLink }]
        : [];
    this.subscriptionServerLists.set(section_id, servers);

    return selectedProxyLink || "";
  };
  const renderSubscriptionProxyLinkWidget = o.renderWidget;
  o.renderWidget = function (section_id, option_index, cfgvalue) {
    const hiddenWidget = renderSubscriptionProxyLinkWidget.apply(this, [
      section_id,
      option_index,
      cfgvalue,
    ]);
    const servers = this.subscriptionServerLists.get(section_id) || [];
    const selectedUrl = cfgvalue || servers[0]?.url || "";
    const subscriptionUrl = uci.get("podkop", section_id, "subscription_url");

    return E(
      "div",
      {
        id: `pdk-subscription-server-picker-${section_id}`,
        class: "pdk-subscription-server-picker",
        "data-subscription-url": subscriptionUrl || "",
        "data-selected-url": selectedUrl,
      },
      [
        E("div", { style: "display: none" }, hiddenWidget),
        E(
          "div",
          {
            id: `pdk-subscription-server-cards-${section_id}`,
            style:
              "display: flex; flex-direction: column; gap: 8px; height: 260px; min-height: 160px; max-height: 70vh; resize: vertical; overflow: auto; padding: 8px 8px 18px; border-radius: 14px; background: rgba(0,0,0,.14); border: 1px solid rgba(255,255,255,.08);",
          },
          renderSubscriptionServerCards(section_id, servers, selectedUrl),
        ),
      ],
    );
  };
  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.TextValue,
    "outbound_json",
    _("Outbound Configuration"),
    _("Enter complete outbound configuration in JSON format"),
  );
  o.depends("proxy_config_type", "outbound");
  o.rows = 10;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateOutboundJson(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.DynamicList,
    "selector_proxy_links",
    _("Selector Proxy Links"),
    _("vless://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links"),
  );
  o.depends("proxy_config_type", "selector");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.DynamicList,
    "urltest_proxy_links",
    _("URLTest Proxy Links"),
    _("vless://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links"),
  );
  o.depends("proxy_config_type", "urltest");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.ListValue,
    "urltest_check_interval",
    _("URLTest Check Interval"),
    _("The interval between connectivity tests"),
  );
  o.value("30s", _("Every 30 seconds"));
  o.value("1m", _("Every 1 minute"));
  o.value("3m", _("Every 3 minutes"));
  o.value("5m", _("Every 5 minutes"));
  o.default = "3m";
  o.depends("proxy_config_type", "urltest");

  o = section.option(
    form.Value,
    "urltest_tolerance",
    _("URLTest Tolerance"),
    _(
      "The maximum difference in response times (ms) allowed when comparing servers",
    ),
  );
  o.default = "50";
  o.rmempty = false;
  o.depends("proxy_config_type", "urltest");
  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const parsed = parseFloat(value);

    if (
      /^[0-9]+$/.test(value) &&
      !isNaN(parsed) &&
      isFinite(parsed) &&
      parsed >= 50 &&
      parsed <= 1000
    ) {
      return true;
    }

    return _("Must be a number in the range of 50 - 1000");
  };

  o = section.option(
    form.Value,
    "urltest_testing_url",
    _("URLTest Testing URL"),
    _("The URL used to test server connectivity"),
  );
  o.value(
    "https://www.gstatic.com/generate_204",
    "https://www.gstatic.com/generate_204 (Google)",
  );
  o.value(
    "https://cp.cloudflare.com/generate_204",
    "https://cp.cloudflare.com/generate_204 (Cloudflare)",
  );
  o.value("https://captive.apple.com", "https://captive.apple.com (Apple)");
  o.value(
    "https://connectivity-check.ubuntu.com",
    "https://connectivity-check.ubuntu.com (Ubuntu)",
  );
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  o.depends("proxy_config_type", "urltest");

  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.Flag,
    "enable_udp_over_tcp",
    _("UDP over TCP"),
    _("Applicable for SOCKS and Shadowsocks proxy"),
  );
  o.default = "0";
  o.depends("connection_type", "proxy");
  o.rmempty = false;

  o = section.option(
    widgets.DeviceSelect,
    "interface",
    _("Network Interface"),
    _("Select network interface for VPN connection"),
  );
  o.depends("connection_type", "vpn");
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = [
      "br-lan",
      "eth0",
      "eth1",
      "wan",
      "phy0-ap0",
      "phy1-ap0",
      "pppoe-wan",
      "lan",
    ];

    // Reject immediately if the value matches any blocked interface
    if (blockedInterfaces.includes(value)) {
      return false;
    }

    // Try to find the device object with the given name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Get the device type (e.g., "wifi", "ethernet", etc.)
    const type = device.getType();

    // Reject wireless-related devices
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    return !isWireless;
  };

  o = section.option(
    form.Flag,
    "domain_resolver_enabled",
    _("Domain Resolver"),
    _("Enable built-in DNS resolver for domains handled by this section"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "vpn");

  o = section.option(
    form.ListValue,
    "domain_resolver_dns_type",
    _("DNS Protocol Type"),
    _("Select the DNS protocol type for the domain resolver"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;
  o.depends("domain_resolver_enabled", "1");

  o = section.option(
    form.Value,
    "domain_resolver_dns_server",
    _("DNS Server"),
    _("Select or enter DNS server address"),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "8.8.8.8";
  o.rmempty = false;
  o.depends("domain_resolver_enabled", "1");
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.DynamicList,
    "community_lists",
    _("Community Lists"),
    _("Select a predefined list for routing") +
      ' <a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>',
  );
  o.placeholder = "Service list";
  Object.entries(main.DOMAIN_LIST_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.rmempty = true;
  let lastValues = [];
  let isProcessing = false;

  o.onchange = function (ev, section_id, value) {
    if (isProcessing) return;
    isProcessing = true;

    try {
      const values = Array.isArray(value) ? value : [value];
      let newValues = [...values];
      let notifications = [];

      const selectedRegionalOptions = main.REGIONAL_OPTIONS.filter((opt) =>
        newValues.includes(opt),
      );

      if (selectedRegionalOptions.length > 1) {
        const lastSelected =
          selectedRegionalOptions[selectedRegionalOptions.length - 1];
        const removedRegions = selectedRegionalOptions.slice(0, -1);
        newValues = newValues.filter(
          (v) => v === lastSelected || !main.REGIONAL_OPTIONS.includes(v),
        );
        notifications.push(
          E("p", {}, [
            E("strong", {}, _("Regional options cannot be used together")),
            E("br"),
            _(
              "Warning: %s cannot be used together with %s. Previous selections have been removed.",
            ).format(removedRegions.join(", "), lastSelected),
          ]),
        );
      }

      if (newValues.includes("russia_inside")) {
        const removedServices = newValues.filter(
          (v) => !main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
        );
        if (removedServices.length > 0) {
          newValues = newValues.filter((v) =>
            main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
          );
          notifications.push(
            E("p", { class: "alert-message warning" }, [
              E("strong", {}, _("Russia inside restrictions")),
              E("br"),
              _(
                "Warning: Russia inside can only be used with %s. %s already in Russia inside and have been removed from selection.",
              ).format(
                main.ALLOWED_WITH_RUSSIA_INSIDE.map(
                  (key) => main.DOMAIN_LIST_OPTIONS[key],
                )
                  .filter((label) => label !== "Russia inside")
                  .join(", "),
                removedServices.join(", "),
              ),
            ]),
          );
        }
      }

      if (JSON.stringify(newValues.sort()) !== JSON.stringify(values.sort())) {
        this.getUIElement(section_id).setValue(newValues);
      }

      notifications.forEach((notification) =>
        ui.addNotification(null, notification),
      );
      lastValues = newValues;
    } catch (e) {
      console.error("Error in onchange handler:", e);
    } finally {
      isProcessing = false;
    }
  };

  o = section.option(
    form.ListValue,
    "user_domain_list_type",
    _("User Domain List Type"),
    _("Select the list type for adding custom domains"),
  );
  o.value("disabled", _("Disabled"));
  o.value("dynamic", _("Dynamic List"));
  o.value("text", _("Text List"));
  o.default = "disabled";
  o.rmempty = false;

  o = section.option(
    form.DynamicList,
    "user_domains",
    _("User Domains"),
    _(
      "Enter domain names without protocols, e.g. example.com or sub.example.com",
    ),
  );
  o.placeholder = "Domains list";
  o.depends("user_domain_list_type", "dynamic");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateDomain(value, true);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.TextValue,
    "user_domains_text",
    _("User Domains List"),
    _(
      "Enter domain names separated by commas, spaces, or newlines. You can add comments using //",
    ),
  );
  o.placeholder =
    "example.com, sub.example.com\n// Social networks\ndomain.com test.com // personal domains";
  o.depends("user_domain_list_type", "text");
  o.rows = 8;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const domains = main.parseValueList(value);

    if (!domains.length) {
      return _(
        "At least one valid domain must be specified. Comments-only content is not allowed.",
      );
    }

    const { valid, results } = main.bulkValidate(domains, (row) =>
      main.validateDomain(row, true),
    );

    if (!valid) {
      const errors = results
        .filter((validation) => !validation.valid) // Leave only failed validations
        .map((validation) => `${validation.value}: ${validation.message}`); // Collect validation errors

      return [_("Validation errors:"), ...errors].join("\n");
    }

    return true;
  };

  o = section.option(
    form.ListValue,
    "user_subnet_list_type",
    _("User Subnet List Type"),
    _("Select the list type for adding custom subnets"),
  );
  o.value("disabled", _("Disabled"));
  o.value("dynamic", _("Dynamic List"));
  o.value("text", _("Text List"));
  o.default = "disabled";
  o.rmempty = false;

  o = section.option(
    form.DynamicList,
    "user_subnets",
    _("User Subnets"),
    _(
      "Enter subnets in CIDR notation (e.g. 103.21.244.0/22) or single IP addresses",
    ),
  );
  o.placeholder = "IP or subnet";
  o.depends("user_subnet_list_type", "dynamic");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.TextValue,
    "user_subnets_text",
    _("User Subnets List"),
    _(
      "Enter subnets in CIDR notation or single IP addresses, separated by commas, spaces, or newlines. " +
        "You can add comments using //",
    ),
  );
  o.placeholder =
    "103.21.244.0/22\n// Google DNS\n8.8.8.8\n1.1.1.1/32, 9.9.9.9 // Cloudflare and Quad9";
  o.depends("user_subnet_list_type", "text");
  o.rows = 10;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const subnets = main.parseValueList(value);

    if (!subnets.length) {
      return _(
        "At least one valid subnet or IP must be specified. Comments-only content is not allowed.",
      );
    }

    const { valid, results } = main.bulkValidate(subnets, main.validateSubnet);

    if (!valid) {
      const errors = results
        .filter((validation) => !validation.valid) // Leave only failed validations
        .map((validation) => `${validation.value}: ${validation.message}`); // Collect validation errors

      return [_("Validation errors:"), ...errors].join("\n");
    }

    return true;
  };

  o = section.option(
    form.DynamicList,
    "local_domain_lists",
    _("Local Domain Lists"),
    _("Specify the path to the list file located on the router filesystem"),
  );
  o.placeholder = "/path/file.lst";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validatePath(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.DynamicList,
    "local_subnet_lists",
    _("Local Subnet Lists"),
    _("Specify the path to the list file located on the router filesystem"),
  );
  o.placeholder = "/path/file.lst";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validatePath(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.DynamicList,
    "remote_domain_lists",
    _("Remote Domain Lists"),
    _("Specify remote URLs to download and use domain lists"),
  );
  o.placeholder = "https://example.com/domains.srs";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.DynamicList,
    "remote_subnet_lists",
    _("Remote Subnet Lists"),
    _("Specify remote URLs to download and use subnet lists"),
  );
  o.placeholder = "https://example.com/subnets.srs";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.DynamicList,
    "fully_routed_ips",
    _("Fully Routed IPs"),
    _(
      "Specify local IP addresses or subnets whose traffic will always be routed through the configured route",
    ),
  );
  o.placeholder = "192.168.1.2 or 192.168.1.0/24";
  o.rmempty = true;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.Flag,
    "mixed_proxy_enabled",
    _("Enable Mixed Proxy"),
    _(
      "Enable the mixed proxy, allowing this section to route traffic through both HTTP and SOCKS proxies",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");

  o = section.option(
    form.Value,
    "mixed_proxy_port",
    _("Mixed Proxy Port"),
    _(
      "Specify the port number on which the mixed proxy will run for this section. " +
        "Make sure the selected port is not used by another service",
    ),
  );
  o.rmempty = false;
  o.depends("mixed_proxy_enabled", "1");

  o = section.option(
    form.Flag,
    "resolve_real_ip_for_routing",
    _("Resolve real IP for routing"),
    _("Enable DNS resolve to get real IP when routing"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");
}

const EntryPoint = {
  createSectionContent,
};

return baseclass.extend(EntryPoint);

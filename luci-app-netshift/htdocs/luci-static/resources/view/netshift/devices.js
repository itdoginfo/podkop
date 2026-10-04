"use strict";
"require baseclass";
"require form";
"require uci";
"require network";
"require view.netshift.main as main";

// Devices tab: route a LAN device (by source IP) fully through one section, or
// send it directly. It does not write UCI itself: it drives the widgets of the
// existing "Fully Routed IPs" (per section) and "Routing Excluded IPs" (settings)
// options, so the normal Save / Save & Apply of the page stores the change and
// the other tabs never overwrite it with a stale value. The logic (state of a
// device, moving it between lists) is main.getDeviceRoute / main.setDeviceRoute.

const FULLY_ROUTED = "fully_routed_ips";
const EXCLUDED = "routing_excluded_ips";

function findOption(section, name) {
  return section.children.find((child) => child.option === name);
}

function widgetList(option, sectionId, uciValue) {
  const element = option?.getUIElement?.(sectionId);
  const value = element?.getValue?.();

  return Array.isArray(value) ? value : main.toIpList(uciValue);
}

function writeWidget(option, sectionId, values) {
  const element = option?.getUIElement?.(sectionId);

  if (element?.setValue) {
    element.setValue(values);
  }
}

// The sections that have the Fully Routed IPs option: proxy and VPN ones (disabled
// ones too, so a device listed there is shown where it really is).
function routedSections() {
  return uci
    .sections("netshift", "section")
    .filter(
      (section) =>
        section.connection_type === "proxy" || section.connection_type === "vpn",
    )
    .map((section) => ({
      name: section[".name"],
      disabled: section.disabled === "1",
    }));
}

function readState(sectionsSection, settingsSection) {
  const fullyRouted = findOption(sectionsSection, FULLY_ROUTED);
  const excluded = findOption(settingsSection, EXCLUDED);
  const sections = {};

  routedSections().forEach(({ name }) => {
    sections[name] = widgetList(
      fullyRouted,
      name,
      uci.get("netshift", name, FULLY_ROUTED),
    );
  });

  return {
    sections,
    excluded: widgetList(
      excluded,
      "settings",
      uci.get("netshift", "settings", EXCLUDED),
    ),
  };
}

function sameList(left, right) {
  return left.length === right.length && left.every((v, i) => v === right[i]);
}

function applyState(before, after, sectionsSection, settingsSection) {
  const fullyRouted = findOption(sectionsSection, FULLY_ROUTED);

  Object.keys(after.sections).forEach((name) => {
    if (!sameList(before.sections[name] ?? [], after.sections[name])) {
      writeWidget(fullyRouted, name, after.sections[name]);
    }
  });

  if (!sameList(before.excluded, after.excluded)) {
    writeWidget(
      findOption(settingsSection, EXCLUDED),
      "settings",
      after.excluded,
    );
  }
}

function ipv4ToNumber(ip) {
  const parts = ip.split(".").map(Number);

  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n))) {
    return Number.MAX_SAFE_INTEGER;
  }

  return parts.reduce((total, n) => total * 256 + n, 0);
}

function collectDevices(hints, state) {
  const devices = new Map();
  const withIpv6 = uci.get("netshift", "settings", "enable_ipv6") === "1";

  hints.getMACHints().forEach(([mac, name]) => {
    const addresses = [hints.getIPAddrByMACAddr(mac)];

    // An IPv6 address only matters when NetShift handles IPv6 traffic.
    if (withIpv6 && hints.getIP6AddrByMACAddr) {
      addresses.push(hints.getIP6AddrByMACAddr(mac));
    }

    addresses.filter(Boolean).forEach((ip) => {
      devices.set(ip, { ip, mac, name: name || "" });
    });
  });

  // Addresses that are in the lists but not on the network right now stay
  // visible, so they can be moved back to the default.
  main.listedDeviceIps(state).forEach((ip) => {
    if (!devices.has(ip)) {
      devices.set(ip, { ip, mac: "", name: "", offline: true });
    }
  });

  return [...devices.values()].sort(
    (a, b) => ipv4ToNumber(a.ip) - ipv4ToNumber(b.ip),
  );
}

// "Direct" is stored in routing_excluded_ips, which takes a bare address only; a
// subnet from Fully Routed IPs is managed in that list, not here.
function isBareAddress(value) {
  return main.validateIP(value).valid;
}

function routeLabel(route) {
  if (route === main.DEVICE_ROUTE_DEFAULT) {
    return _("Default (by the lists)");
  }

  if (route === main.DEVICE_ROUTE_EXCLUDED) {
    return _("Direct (excluded from routing)");
  }

  return _("Everything through: %s").format(route);
}

function buildDevices(sectionsSection, settingsSection) {
  const tableBody = E("tbody");
  let hints = null;

  const renderRows = () => {
    const state = readState(sectionsSection, settingsSection);
    const disabled = new Set(
      routedSections()
        .filter((section) => section.disabled)
        .map((section) => section.name),
    );
    const enabledRoutes = Object.keys(state.sections).filter(
      (name) => !disabled.has(name),
    );

    tableBody.replaceChildren();

    collectDevices(hints, state).forEach((device) => {
      const current = main.getDeviceRoute(state, device.ip);
      // Disabled sections are not offered as a target, but a device that is
      // listed in one still shows it (marked), so the state is not misreported.
      const routes = [main.DEVICE_ROUTE_DEFAULT, main.DEVICE_ROUTE_EXCLUDED]
        .concat(enabledRoutes)
        .concat(disabled.has(current) ? [current] : [])
        .filter(
          (route) =>
            route !== main.DEVICE_ROUTE_EXCLUDED || isBareAddress(device.ip),
        );
      const select = E(
        "select",
        {
          class: "cbi-input-select",
          change: (ev) => {
            const before = readState(sectionsSection, settingsSection);
            const after = main.setDeviceRoute(before, device.ip, ev.target.value);

            applyState(before, after, sectionsSection, settingsSection);
            renderRows();
          },
        },
        routes.map((route) =>
          E(
            "option",
            { value: route, selected: route === current ? "" : null },
            [routeLabel(route) + (disabled.has(route) ? " " + _("(disabled)") : "")],
          ),
        ),
      );

      tableBody.appendChild(
        E("tr", { class: "tr" }, [
          E("td", { class: "td" }, [
            device.name || (device.offline ? _("Not on the network") : "-"),
          ]),
          E("td", { class: "td" }, [device.ip]),
          E("td", { class: "td" }, [device.mac || "-"]),
          E("td", { class: "td" }, [select]),
        ]),
      );
    });
  };

  // The host hints arrive asynchronously; the table is filled when they are here.
  network
    .getHostHints()
    .then((result) => {
      hints = result;
      renderRows();
    })
    .catch(() => {
      hints = { getMACHints: () => [], getIPAddrByMACAddr: () => null };
      renderRows();
    });

  return E("div", { class: "cbi-section" }, [
    E("div", { class: "cbi-section-descr" }, [
      _(
        "Choose how traffic of a device in your network is handled. A device can be sent completely through one section (all its traffic) or directly, ignoring the lists. The change is stored with the page's Save & Apply, like the other settings.",
      ),
    ]),
    E("div", { class: "table" }, [
      E("table", { class: "table" }, [
        E("thead", {}, [
          E("tr", { class: "tr table-titles" }, [
            E("th", { class: "th" }, [_("Device")]),
            E("th", { class: "th" }, [_("IP address")]),
            E("th", { class: "th" }, [_("MAC address")]),
            E("th", { class: "th" }, [_("Routing")]),
          ]),
        ]),
        tableBody,
      ]),
    ]),
  ]);
}

function createDevicesContent(devicesSection, sectionsSection, settingsSection) {
  const o = devicesSection.option(form.DummyValue, "_devices");

  o.render = function () {
    return Promise.resolve(
      E("div", { class: "cbi-value" }, [
        buildDevices(sectionsSection, settingsSection),
      ]),
    );
  };
}

const EntryPoint = {
  createDevicesContent,
};

return baseclass.extend(EntryPoint);

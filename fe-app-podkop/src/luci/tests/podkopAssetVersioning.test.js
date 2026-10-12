import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const podkopViewPath = resolve(
  import.meta.dirname,
  '../../../../luci-app-podkop/htdocs/luci-static/resources/view/podkop/podkop.js',
);

function createModuleMocks() {
  return {
    'view.podkop.main': {
      injectGlobalStyles() {},
      coreService() {},
    },
    'view.podkop.settings': {
      createSettingsContent() {},
    },
    'view.podkop.section': {
      createSectionContent() {},
    },
    'view.podkop.dashboard': {
      createDashboardContent() {},
    },
    'view.podkop.diagnostic': {
      createDiagnosticContent() {},
    },
  };
}

function createFormMock() {
  class Map {
    constructor() {
      this.sections = [];
    }

    section() {
      const section = {};
      this.sections.push(section);
      return section;
    }

    render() {
      return 'rendered';
    }
  }

  return {
    Map,
    TypedSection: class {},
  };
}

function loadPodkopView({ compiledAssetVersion, uiAssetVersion }) {
  const source = readFileSync(podkopViewPath, 'utf8').replaceAll(
    '__COMPILED_ASSET_VERSION_VARIABLE__',
    compiledAssetVersion,
  );

  const requireCalls = [];
  const moduleMocks = createModuleMocks();
  const L = {
    env: {
      resource_version: 'openwrt-resource-version',
    },
    require: async (name) => {
      requireCalls.push({
        name,
        resourceVersion: L.env.resource_version,
      });
      return moduleMocks[name];
    },
  };

  const uci = {
    load: async () => {},
    get: () => uiAssetVersion,
  };

  const view = {
    extend: (entryPoint) => entryPoint,
  };

  const baseclass = {
    extend: (entryPoint) => entryPoint,
  };

  const entryPoint = new Function(
    'view',
    'form',
    'baseclass',
    'network',
    'uci',
    'L',
    '_',
    source,
  )(
    view,
    createFormMock(),
    baseclass,
    {},
    uci,
    L,
    (value) => value,
  );

  return {
    entryPoint,
    L,
    requireCalls,
    source,
  };
}

describe('podkop LuCI asset versioning', () => {
  it('loads Podkop view modules with the UCI asset version', async () => {
    const { entryPoint, L, requireCalls } = loadPodkopView({
      compiledAssetVersion: '1.2.3-1',
      uiAssetVersion: '1.2.3-4',
    });

    await expect(entryPoint.render()).resolves.toBe('rendered');

    expect(requireCalls).toEqual([
      {
        name: 'view.podkop.main',
        resourceVersion: 'podkop-1.2.3-4',
      },
      {
        name: 'view.podkop.settings',
        resourceVersion: 'podkop-1.2.3-4',
      },
      {
        name: 'view.podkop.section',
        resourceVersion: 'podkop-1.2.3-4',
      },
      {
        name: 'view.podkop.dashboard',
        resourceVersion: 'podkop-1.2.3-4',
      },
      {
        name: 'view.podkop.diagnostic',
        resourceVersion: 'podkop-1.2.3-4',
      },
    ]);
    expect(L.env.resource_version).toBe('openwrt-resource-version');
  });

  it('falls back to the compiled asset version', async () => {
    const { entryPoint, requireCalls } = loadPodkopView({
      compiledAssetVersion: '2.0.0-7',
      uiAssetVersion: '',
    });

    await expect(entryPoint.render()).resolves.toBe('rendered');

    expect(
      requireCalls.every(
        ({ resourceVersion }) => resourceVersion === 'podkop-2.0.0-7',
      ),
    ).toBe(true);
  });

  it('sanitizes the asset version before using it in LuCI resource URLs', async () => {
    const { entryPoint, requireCalls } = loadPodkopView({
      compiledAssetVersion: '2.0.0-7',
      uiAssetVersion: '2.0.0 release/7',
    });

    await expect(entryPoint.render()).resolves.toBe('rendered');

    expect(requireCalls[0].resourceVersion).toBe('podkop-2.0.0_release_7');
  });
});

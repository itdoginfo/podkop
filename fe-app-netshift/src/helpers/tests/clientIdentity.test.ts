import { describe, expect, it } from 'vitest';
import {
  CLIENT_IDENTITY_PROFILES,
  generateClientIdentity,
} from '../clientIdentity';

// The rule of Remnawave: a panel ignores any other X-HWID.
const PANEL_HWID = /^[A-Za-z0-9=-]{10,64}$/;

describe('generateClientIdentity', () => {
  it('builds Happ on Android like the app', () => {
    const identity = generateClientIdentity('Happ', 'Android');

    expect(identity?.user_agent).toMatch(
      /^Happ\/\d+\.\d+\.\d+\/Android\/[1-9]\d{19}$/,
    );
    expect(identity?.hwid).toMatch(/^[0-9a-f]{16}$/);
    expect(identity?.device_os).toBe('Android');
  });

  it('builds the INCY hash in the UUID layout, without a version digit', () => {
    // A random source that gives 0 everywhere would make uuid() put its '4' in.
    const hwid = generateClientIdentity('INCY', 'iOS', () => 0)?.hwid;

    expect(hwid).toBe('00000000-0000-0000-0000-000000000000');
    expect(generateClientIdentity('INCY', 'Android')?.hwid).toMatch(
      /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/,
    );
  });

  it('builds a UUID v4 for Happ on Windows', () => {
    expect(generateClientIdentity('Happ', 'Windows')?.hwid).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
  });

  it('sends only User-Agent and OS version pairs real devices sent', () => {
    for (const [app, platforms] of Object.entries(CLIENT_IDENTITY_PROFILES)) {
      for (const [platform, profile] of Object.entries(platforms)) {
        const pairs = profile.variants.map(
          ([userAgent, os]) => `${userAgent} ${os}`,
        );

        for (let i = 0; i < 50; i++) {
          const identity = generateClientIdentity(app, platform);
          const userAgent = identity?.user_agent.replace(
            /\/\d{20}$/,
            '/{install}',
          );

          expect(pairs).toContain(`${userAgent} ${identity?.os_version}`);
        }
      }
    }
  });

  it('picks the versions in proportion to the panel', () => {
    const versions = (random: number) =>
      generateClientIdentity('INCY', 'iOS', () => random)?.user_agent;

    // The first pair holds 13 of 50 devices: the low quarter of the range.
    expect(versions(0)).toContain('Darwin/27.0.0');
    expect(versions(0.25)).toContain('Darwin/27.0.0');
    expect(versions(0.27)).not.toContain('Darwin/27.0.0');
    expect(versions(0.999999)).toContain('Darwin/24.6.0');

    const seen = new Set<string>();
    for (let i = 0; i < 300; i++) {
      seen.add(
        generateClientIdentity('Happ', 'Android')?.user_agent.split('/')[1] ??
          '',
      );
    }
    expect(seen.size).toBeGreaterThan(1);
  });

  it('puts a fresh install number and computer name in', () => {
    expect(generateClientIdentity('Happ', 'Windows')?.device_model).toMatch(
      /^DESKTOP-[0-9A-Z]{7}_x86_64$/,
    );
  });

  it('gives a new HWID every time', () => {
    expect(generateClientIdentity('Happ', 'iOS')?.hwid).not.toBe(
      generateClientIdentity('Happ', 'iOS')?.hwid,
    );
  });

  it('fills every field the panel accepts, on every profile', () => {
    for (const [app, platforms] of Object.entries(CLIENT_IDENTITY_PROFILES)) {
      for (const platform of Object.keys(platforms)) {
        // The edges of the random range must not fall outside the lists.
        for (const value of [0, 0.999999]) {
          const identity = generateClientIdentity(app, platform, () => value);

          expect(identity?.hwid).toMatch(PANEL_HWID);
          expect(identity?.user_agent.startsWith(`${app}/`)).toBe(true);
          expect(identity?.os_version).toBeTruthy();
          expect(identity?.device_model).toBeTruthy();
        }
      }
    }
  });

  it('knows no unknown pair', () => {
    expect(generateClientIdentity('Happ', 'Symbian')).toBeNull();
    expect(generateClientIdentity('Nope', 'Android')).toBeNull();
  });
});

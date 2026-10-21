import { afterEach, describe, expect, it, vi } from 'vitest';
import { onFirstVisible } from '../onFirstVisible';

type Callback = (
  entries: Array<{ intersectionRect: { width: number; height: number } }>,
) => void;

const on = [{ intersectionRect: { width: 100, height: 20 } }];
const off = [{ intersectionRect: { width: 0, height: 0 } }];
// a tab LuCI 26 hides: height 0, touching the edge of the screen
const hiddenTab = [{ intersectionRect: { width: 999, height: 0 } }];

const observers: Array<{ callback: Callback; disconnected: boolean }> = [];

function installObserver() {
  vi.stubGlobal(
    'IntersectionObserver',
    class {
      record: { callback: Callback; disconnected: boolean };

      constructor(callback: Callback) {
        this.record = { callback, disconnected: false };
        observers.push(this.record);
      }

      observe() {}

      disconnect() {
        this.record.disconnected = true;
      }
    },
  );
}

afterEach(() => {
  observers.length = 0;
  vi.unstubAllGlobals();
});

describe('onFirstVisible', () => {
  it('waits until the node is on screen, then runs once', () => {
    installObserver();
    const callback = vi.fn();

    onFirstVisible({} as Element, callback);
    expect(callback).not.toHaveBeenCalled();

    observers[0].callback(off);
    observers[0].callback(hiddenTab);
    expect(callback).not.toHaveBeenCalled();

    observers[0].callback(on);
    observers[0].callback(on);
    expect(callback).toHaveBeenCalledTimes(1);
    expect(observers[0].disconnected).toBe(true);
  });

  it('runs at once without IntersectionObserver', () => {
    vi.stubGlobal('IntersectionObserver', undefined);
    const callback = vi.fn();

    onFirstVisible({} as Element, callback);
    expect(callback).toHaveBeenCalledTimes(1);
  });
});

describe('watchVisibility', () => {
  it('follows the node in and out of the screen', async () => {
    installObserver();
    const { watchVisibility } = await import('../onFirstVisible');
    const node = { isConnected: true } as HTMLElement;
    const visible = watchVisibility(node);

    expect(visible()).toBe(false);
    observers[0].callback(on);
    expect(visible()).toBe(true);
    observers[0].callback(hiddenTab);
    expect(visible()).toBe(false);
  });

  it('is false and stops watching once the node is gone', async () => {
    installObserver();
    const { watchVisibility } = await import('../onFirstVisible');
    const node = { isConnected: true } as { isConnected: boolean };
    const visible = watchVisibility(node as HTMLElement);

    observers[0].callback(on);
    node.isConnected = false;
    expect(visible()).toBe(false);
    expect(observers[0].disconnected).toBe(true);
  });
});

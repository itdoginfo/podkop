import { afterEach, describe, expect, it, vi } from 'vitest';
import { onMount } from '../onMount';

type Rect = { width: number; height: number };
type IoCallback = (entries: Array<{ intersectionRect: Rect }>) => void;

const intersections: Array<{ callback: IoCallback; target: unknown }> = [];
let mutationCallback: (() => void) | null = null;
const elements: Record<string, unknown> = {};

function element(pane: unknown) {
  return { closest: () => pane };
}

function install() {
  vi.stubGlobal(
    'IntersectionObserver',
    class {
      record: { callback: IoCallback; target: unknown };

      constructor(callback: IoCallback) {
        this.record = { callback, target: null };
        intersections.push(this.record);
      }

      observe(target: unknown) {
        this.record.target = target;
      }

      disconnect() {}
    },
  );
  vi.stubGlobal(
    'MutationObserver',
    class {
      constructor(callback: () => void) {
        mutationCallback = callback;
      }

      observe() {}

      disconnect() {}
    },
  );
  vi.stubGlobal('document', {
    body: {},
    getElementById: (id: string) => elements[id] ?? null,
  });
}

afterEach(() => {
  intersections.length = 0;
  mutationCallback = null;
  Object.keys(elements).forEach((key) => delete elements[key]);
  vi.unstubAllGlobals();
});

const on = [{ intersectionRect: { width: 100, height: 40 } }];
const hiddenTab = [{ intersectionRect: { width: 999, height: 0 } }];

describe('onMount', () => {
  it('waits for the pane of the tab to be on screen, not for an offsetParent', async () => {
    install();
    const pane = { name: 'pane' };
    elements.x = element(pane);
    const resolved = vi.fn();

    onMount('x').then(resolved);
    expect(intersections[0].target).toBe(pane);

    intersections[0].callback(hiddenTab);
    await new Promise((r) => setTimeout(r, 0));
    expect(resolved).not.toHaveBeenCalled();

    intersections[0].callback(on);
    await new Promise((r) => setTimeout(r, 0));
    expect(resolved).toHaveBeenCalledWith(elements.x);
  });

  it('follows an element that LuCI drew again with the same id', async () => {
    install();
    elements.x = element({ name: 'first pane' });
    const resolved = vi.fn();

    onMount('x').then(resolved);
    const secondPane = { name: 'second pane' };
    elements.x = element(secondPane);
    mutationCallback?.();

    expect(intersections[1].target).toBe(secondPane);
    intersections[1].callback(on);
    await new Promise((r) => setTimeout(r, 0));
    expect(resolved).toHaveBeenCalledWith(elements.x);
  });

  it('waits for an element that is not there yet', async () => {
    install();
    const resolved = vi.fn();

    onMount('later').then(resolved);
    expect(intersections).toHaveLength(0);

    elements.later = element({ name: 'pane' });
    mutationCallback?.();
    intersections[0].callback(on);
    await new Promise((r) => setTimeout(r, 0));
    expect(resolved).toHaveBeenCalledWith(elements.later);
  });
});

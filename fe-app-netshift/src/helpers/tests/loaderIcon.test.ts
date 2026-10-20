import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderLoaderCircleIcon24 } from '../../icons/renderLoaderCircleIcon24';

// styles.ts pulls in the tabs (TabService needs a MutationObserver): only their styles matter
vi.mock('../../netshift', () => ({
  DashboardTab: { styles: '' },
  DiagnosticTab: { styles: '' },
  ManagerTab: { styles: '' },
}));

const { GlobalStyles } = await import('../../styles');

// The loader icon is the <svg> itself, and the `.rotate` CSS class spins it around
// its own centre. A SMIL <animateTransform> inside it turns the <svg> element too,
// but around the point (12, 12) of the PAGE coordinates of its parent: the circle
// then orbits away from its button (on a phone it ended up over the neighbouring
// button) while a subscription, NetShift or a component was being refreshed.

// The tests run without a DOM: a minimal element is enough to see what the icon is made of.
interface FakeElement {
  tag: string;
  attrs: Record<string, string>;
  children: FakeElement[];
  setAttribute(name: string, value: string): void;
  appendChild(child: FakeElement): void;
}

function fakeElement(tag: string): FakeElement {
  return {
    tag,
    attrs: {},
    children: [],
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    appendChild(child) {
      this.children.push(child);
    },
  };
}

function tags(element: FakeElement): string[] {
  return [element.tag, ...element.children.flatMap(tags)];
}

const globals = globalThis as unknown as { document?: unknown };
let savedDocument: unknown;

beforeEach(() => {
  savedDocument = globals.document;
  globals.document = {
    createElementNS: (_ns: string, tag: string) => fakeElement(tag),
  };
});

afterEach(() => {
  globals.document = savedDocument;
});

describe('loader circle icon', () => {
  it('is spun by the stylesheet only, not by a transform animation on the svg root', () => {
    const icon = renderLoaderCircleIcon24() as unknown as FakeElement;

    expect(tags(icon)).not.toContain('animateTransform');
    expect(icon.attrs.class.split(' ')).toContain('rotate');
  });

  it('has a rotate rule that turns it around its centre', () => {
    const rule = /\.rotate\s*\{([^}]*)\}/.exec(GlobalStyles)?.[1] ?? '';

    expect(rule).toContain('animation: spin');
    expect(rule).toContain('transform-origin: 50% 50%');
    expect(GlobalStyles).toMatch(/@keyframes spin/);
  });
});

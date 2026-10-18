import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

// The loader icon is the <svg> itself, and the `.rotate` CSS class spins it around
// its own centre. A SMIL <animateTransform> inside it turns the <svg> element too,
// but around the point (12, 12) of the PAGE coordinates of its parent: the circle
// then orbits away from its button (on a phone it ended up over the neighbouring
// button) while a subscription, NetShift or a component was being refreshed.
const read = (file: string) => readFileSync(resolve(__dirname, file), 'utf8');

describe('loader circle icon', () => {
  it('is spun by the stylesheet only, not by a transform animation on the svg root', () => {
    const icon = read('../../icons/renderLoaderCircleIcon24.ts');

    expect(icon).not.toContain('animateTransform');
    expect(icon).toContain('rotate');
  });

  it('has a rotate rule that turns it around its centre', () => {
    const styles = read('../../styles.ts');
    const rule = /\.rotate\s*\{([^}]*)\}/.exec(styles)?.[1] ?? '';

    expect(rule).toContain('animation: spin');
    expect(rule).toContain('transform-origin: 50% 50%');
    expect(styles).toMatch(/@keyframes spin/);
  });
});

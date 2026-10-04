import { describe, expect, it } from 'vitest';
import { withCountryFlag } from '../withCountryFlag';

describe('withCountryFlag', () => {
  it('puts the flag in front of a name without one', () => {
    expect(withCountryFlag('Amsterdam', 'NL')).toBe('🇳🇱 Amsterdam');
  });

  it('accepts a lowercase code', () => {
    expect(withCountryFlag('Tokyo', 'jp')).toBe('🇯🇵 Tokyo');
  });

  it('leaves a name that already has a flag alone', () => {
    expect(withCountryFlag('🇩🇪 Berlin', 'NL')).toBe('🇩🇪 Berlin');
    expect(withCountryFlag('Premium 🇳🇱', 'DE')).toBe('Premium 🇳🇱');
  });

  it('ignores a missing or malformed code', () => {
    expect(withCountryFlag('Oslo')).toBe('Oslo');
    expect(withCountryFlag('Oslo', '')).toBe('Oslo');
    expect(withCountryFlag('Oslo', 'NOR')).toBe('Oslo');
    expect(withCountryFlag('Oslo', '1a')).toBe('Oslo');
  });

  it('shows just the flag for an empty name', () => {
    expect(withCountryFlag('', 'FR')).toBe('🇫🇷');
  });
});

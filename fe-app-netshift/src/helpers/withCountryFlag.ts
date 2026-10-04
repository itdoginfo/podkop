const FLAG_PAIR = /[\u{1F1E6}-\u{1F1FF}]{2}/u;
const REGIONAL_INDICATOR_A = 0x1f1e6;

// Puts the flag of the two-letter country code in front of a server name that has
// none. A name that already carries a flag, or a code that is not two letters,
// is returned unchanged.
export function withCountryFlag(name: string, countryCode?: string): string {
  if (!countryCode || !/^[A-Za-z]{2}$/.test(countryCode)) {
    return name;
  }

  if (FLAG_PAIR.test(name)) {
    return name;
  }

  const flag = String.fromCodePoint(
    ...countryCode
      .toUpperCase()
      .split('')
      .map((letter) => REGIONAL_INDICATOR_A + letter.charCodeAt(0) - 65),
  );

  return name ? `${flag} ${name}` : flag;
}

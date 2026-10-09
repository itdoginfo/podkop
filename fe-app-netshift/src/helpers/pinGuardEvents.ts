// What the pin guard did (netshift get_pin_guard_events): it left a server that was
// chosen by hand and stopped answering. Shown on the dashboard for a day.

export interface PinGuardEvent {
  time: number;
  section: string;
  from: string;
  to: string;
}

export const PIN_GUARD_SHOW_SECONDS = 86400;

export function parsePinGuardEvents(input: unknown): PinGuardEvent[] {
  let data: unknown = input;

  if (typeof input === 'string') {
    try {
      data = JSON.parse(input);
    } catch {
      return [];
    }
  }

  if (!Array.isArray(data)) {
    return [];
  }

  return data
    .filter(
      (item) =>
        item &&
        typeof item.time === 'number' &&
        typeof item.section === 'string' &&
        typeof item.from === 'string' &&
        typeof item.to === 'string',
    )
    .map((item) => ({
      time: item.time,
      section: item.section,
      from: item.from,
      to: item.to,
    }));
}

// The events worth showing now (newest first): not older than a day.
export function recentPinGuardEvents(
  events: PinGuardEvent[],
  now: number,
): PinGuardEvent[] {
  return events
    .filter((event) => now - event.time <= PIN_GUARD_SHOW_SECONDS)
    .sort((a, b) => b.time - a.time);
}

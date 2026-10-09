// The log lines that become notifications. A list of thousands of servers can write a
// line for every odd link, and a wall of identical notifications hides the one that
// matters, so the lines that one poll of the log brings are grouped: the same message
// (the time of the line aside) is shown once with how many times it came, and only the
// first few different messages are shown at all. A [fatal] message is never left out:
// it is shown first, whatever came before it.

export interface LogErrorSummary {
  message: string;
  count: number;
}

export interface LogErrorBatch {
  shown: LogErrorSummary[];
  // The log lines (not messages) that were left out.
  hiddenLines: number;
}

const isFatal = (message: string) => message.toLowerCase().includes('[fatal]');

// "Wed Oct 7 14:34:24 2026 user.notice netshift: [error] text" -> "[error] text"
export function logLineMessage(line: string): string {
  const marker = line.indexOf('netshift: ');

  return (marker >= 0 ? line.slice(marker + 'netshift: '.length) : line).trim();
}

export function summarizeLogErrors(
  lines: string[],
  maxShown = 3,
): LogErrorBatch {
  const groups = new Map<string, LogErrorSummary>();

  lines.forEach((line) => {
    const message = logLineMessage(line);
    const group = groups.get(message);

    if (group) {
      group.count += 1;
    } else {
      groups.set(message, { message, count: 1 });
    }
  });

  // [fatal] first (the order of arrival is kept inside each kind), and all of them are
  // shown even when there are more than maxShown.
  const all = Array.from(groups.values());
  const fatal = all.filter((item) => isFatal(item.message));
  const others = all.filter((item) => !isFatal(item.message));
  const room = Math.max(0, maxShown - fatal.length);
  const shown = [...fatal, ...others.slice(0, room)];
  const hidden = others.slice(room);

  return {
    shown,
    hiddenLines: hidden.reduce((sum, item) => sum + item.count, 0),
  };
}

// Collects the lines that arrive in one go and hands the summary over once, right after
// that go: the log watcher delivers everything one poll brought in a single synchronous
// loop, so a zero-delay timer fires when the loop is over (no waiting for a quiet period).
export function createLogErrorBatcher(
  onFlush: (batch: LogErrorBatch) => void,
  schedule: (callback: () => void) => unknown = (callback) =>
    setTimeout(callback, 0),
) {
  let pending: string[] = [];
  let scheduled = false;

  return {
    push(line: string) {
      pending.push(line);

      if (!scheduled) {
        scheduled = true;
        schedule(() => {
          scheduled = false;

          const lines = pending;

          pending = [];
          onFlush(summarizeLogErrors(lines));
        });
      }
    },
  };
}

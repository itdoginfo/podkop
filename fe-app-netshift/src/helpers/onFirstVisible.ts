// Visibility of a part of the page, for work that only one tab of NetShift
// shows. NetShift builds every tab at once, and LuCI 26 hides a tab that is
// not open with height 0 and overflow hidden (not display: none): such a tab
// still has an offsetParent, and an IntersectionObserver reports it as
// "intersecting" with an area of 0 (touching the edge of the screen). On
// screen here means: some area of the node can be seen.
type Entry = Pick<IntersectionObserverEntry, 'intersectionRect'>;

export function isOnScreen(entries: Entry[]) {
  return entries.some(
    (entry) =>
      entry.intersectionRect.width > 0 && entry.intersectionRect.height > 0,
  );
}

// Runs `callback` once, the first time `node` is on screen. Work such as a DNS
// speed test, the list of connections or the devices of the LAN would
// otherwise run on every visit, before the user has opened that tab: each of
// them is a netshift command on the router, and LuCI sends the calls of one
// moment together, so they all delay the first answer. Where the browser has
// no IntersectionObserver the callback runs at once, as before.
export function onFirstVisible(node: Element, callback: () => void) {
  if (typeof IntersectionObserver === 'undefined') {
    callback();
    return;
  }

  let done = false;
  const observer = new IntersectionObserver((entries) => {
    if (done || !isOnScreen(entries)) {
      return;
    }

    done = true;
    observer.disconnect();
    callback();
  });

  observer.observe(node);
}

// Tells, at any time, whether `node` is on screen now: for a page that polls
// the router only while its tab is open. Without IntersectionObserver it falls
// back to offsetParent.
export function watchVisibility(node: HTMLElement): () => boolean {
  if (typeof IntersectionObserver === 'undefined') {
    return () => node.offsetParent !== null;
  }

  let visible = false;
  const observer = new IntersectionObserver((entries) => {
    visible = isOnScreen(entries);
  });

  observer.observe(node);

  return () => {
    if (!node.isConnected) {
      observer.disconnect();
      return false;
    }

    return visible;
  };
}

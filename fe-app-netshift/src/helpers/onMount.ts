import { isOnScreen } from './onFirstVisible';

// Resolves with the element `id` once it is on screen (its tab opened). The
// tab controllers start from here.
//
// - offsetParent cannot tell: LuCI 26 hides a tab that is not open with
//   height 0 and overflow hidden, not display: none, so every controller used
//   to start on the first visit with all its calls to the router.
// - The pane of the tab is watched, not the element: a placeholder may have no
//   height of its own until its controller fills it.
// - LuCI may draw the option twice, and the element seen first is then
//   replaced by a new one with the same id: the newest one is followed.
export async function onMount(id: string): Promise<HTMLElement> {
  return new Promise((resolve) => {
    let watched: Element | null = null;
    let intersection: IntersectionObserver | null = null;
    let mutation: MutationObserver | null = null;
    let resize: ResizeObserver | null = null;
    let done = false;

    const finish = (element: HTMLElement) => {
      if (done) {
        return;
      }

      done = true;
      mutation?.disconnect();
      intersection?.disconnect();
      resize?.disconnect();
      resolve(element);
    };

    const follow = () => {
      const target = document.getElementById(id);

      if (!target) {
        return;
      }

      if (typeof IntersectionObserver === 'undefined') {
        finish(target);
        return;
      }

      // A placeholder with nothing in it has no height, and a tab that is open but empty
      // (the components manager fills its tab only after it has started) would never count as
      // seen. One pixel makes it visible; a tab that is not open is still clipped to nothing.
      if (!target.style.minHeight) {
        target.style.minHeight = '1px';
      }

      // LuCI marks the pane of a tab with data-tab-title (cbi.js and form.js, 24.10 and later)
      const pane = target.closest('[data-tab-title], [data-tab]') ?? target;

      if (pane === watched) {
        return;
      }

      intersection?.disconnect();
      resize?.disconnect();
      watched = pane;
      intersection = new IntersectionObserver((entries) => {
        if (isOnScreen(entries)) {
          finish(document.getElementById(id) ?? target);
        }
      });
      intersection.observe(pane);

      // An observer of intersection reports a change of the state, and a hidden pane and a
      // pane of one pixel are both "intersecting": opening a tab that is empty gives no event.
      // The size of the pane does change.
      // Not when the element itself is watched (no pane found): its own min-height would
      // then count at once, a resize observer measures the box before the clipping of a parent,
      // and the intersection observer with that min-height already tells open from closed.
      if (pane !== target && typeof ResizeObserver !== 'undefined') {
        resize = new ResizeObserver(() => {
          const { width, height } = pane.getBoundingClientRect();

          if (width > 0 && height > 0) {
            finish(document.getElementById(id) ?? target);
          }
        });
        resize.observe(pane);
      }
    };

    mutation = new MutationObserver(follow);
    mutation.observe(document.body, { childList: true, subtree: true });
    follow();
  });
}

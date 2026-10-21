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
    let done = false;

    const finish = (element: HTMLElement) => {
      if (done) {
        return;
      }

      done = true;
      mutation?.disconnect();
      intersection?.disconnect();
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

      const pane = target.closest('[data-tab-title]') ?? target;

      if (pane === watched) {
        return;
      }

      intersection?.disconnect();
      watched = pane;
      intersection = new IntersectionObserver((entries) => {
        if (isOnScreen(entries)) {
          finish(document.getElementById(id) ?? target);
        }
      });
      intersection.observe(pane);
    };

    mutation = new MutationObserver(follow);
    mutation.observe(document.body, { childList: true, subtree: true });
    follow();
  });
}

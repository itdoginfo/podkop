export async function onMount(id: string): Promise<HTMLElement> {
  return new Promise((resolve) => {
    const el = document.getElementById(id);

    if (el && el.offsetParent !== null) {
      return resolve(el);
    }

    const observer = new MutationObserver(() => {
      const target = document.getElementById(id);
      if (target) {
        const io = new IntersectionObserver((entries) => {
          const visible = entries.some((e) => e.isIntersecting);
          if (visible) {
            observer.disconnect();
            io.disconnect();
            resolve(target);
          }
        });

        io.observe(target);
      }
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true,
    });
  });
}

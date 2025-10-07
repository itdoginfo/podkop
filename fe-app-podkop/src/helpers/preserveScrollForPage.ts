export function preserveScrollForPage(renderFn: () => void) {
  const scrollY = window.scrollY;

  renderFn();

  requestAnimationFrame(() => {
    window.scrollTo({ top: scrollY });
  });
}

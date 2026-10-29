/**
 * Lights the edge of each matching element nearest the pointer, wherever the pointer is
 * on the page. The element's CSS reads the pointer position from `--x` and `--y`.
 */
export function spotlight(selector: string) {
  const elements = [...document.querySelectorAll<HTMLElement>(selector)];
  if (!elements.length) return;
  document.addEventListener("pointermove", event => {
    for (const element of elements) {
      const box = element.getBoundingClientRect();
      element.style.setProperty("--x", `${event.clientX - box.left}px`);
      element.style.setProperty("--y", `${event.clientY - box.top}px`);
    }
  });
}

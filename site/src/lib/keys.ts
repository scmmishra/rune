/**
 * Presses the element that matches a key the visitor types. An element names its key in
 * `data-key` (KeyboardEvent.key, lowercased), and whether ⇧ and ⌘ are held in `data-shift`
 * and `data-meta`. Both default to "false" and "true". Only matching keys are taken from
 * the browser, and only while the page has focus.
 */
export function lightKeys() {
  const keys = [...document.querySelectorAll<HTMLElement>("[data-key]")];
  document.addEventListener("keydown", event => {
    if (event.altKey || event.ctrlKey || event.repeat) return;
    const key = event.key.toLowerCase();
    const match = keys.find(item =>
      item.dataset.key === key &&
      (item.dataset.shift ?? "false") === String(event.shiftKey) &&
      (item.dataset.meta ?? "true") === String(event.metaKey));
    if (!match) return;
    // A plain letter belongs to a text field when one has focus.
    if (!event.metaKey && event.target instanceof HTMLElement && event.target.closest("input, textarea")) return;
    event.preventDefault();
    match.classList.remove("pressed");
    void match.offsetWidth;
    match.classList.add("pressed");
  });
  for (const item of keys) item.addEventListener("animationend", () => item.classList.remove("pressed"));
}

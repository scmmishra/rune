import { Marked } from "marked";
import { REPO } from "./site";

/**
 * The docs pages are the repository's own `docs/*.md`, so the site and the specs never
 * disagree. Links between them become site links. Links out of the folder go to GitHub.
 */
const files = import.meta.glob("../../../docs/*.md", { query: "?raw", import: "default", eager: true }) as Record<string, string>;

export type Doc = { slug: string; title: string; html: string };

const ORDER = ["README", "spaces", "layout", "cards", "agent-control"];

function rewrite(href: string): string {
  if (/^[a-z]+:/i.test(href) || href.startsWith("#")) return href;
  const [path, hash] = href.split("#");
  const anchor = hash ? `#${hash}` : "";
  const local = path.match(/^(?:\.\/)?([\w-]+)\.md$/);
  if (local) return (local[1] === "README" ? "/docs" : `/docs/${local[1]}`) + anchor;
  if (path.startsWith("../")) return `${REPO}/blob/main/${path.slice(3)}${anchor}`;
  return `${REPO}/blob/main/docs/${path}${anchor}`;
}

const marked = new Marked({
  walkTokens(token) {
    if (token.type === "link") token.href = rewrite(token.href);
  },
});

export const docs: Doc[] = Object.entries(files)
  .map(([file, text]) => {
    const name = file.split("/").pop()!.replace(/\.md$/, "");
    const title = text.match(/^#\s+(.+)$/m)?.[1] ?? name;
    // The page prints its title in the layout, so the file's own heading is dropped.
    const body = text.replace(/^#\s+.+\n/m, "");
    return { slug: name === "README" ? "" : name, title, html: marked.parse(body, { async: false }) as string, name };
  })
  .sort((a, b) => ORDER.indexOf(a.name) - ORDER.indexOf(b.name))
  .map(({ slug, title, html }) => ({ slug, title, html }));

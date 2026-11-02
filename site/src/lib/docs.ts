import { Marked } from "marked";
import { REPO } from "./site";

/**
 * The docs pages are the repository's own `docs/*.md`, so the site and the specs never
 * disagree. Links between them become site links. Links out of the folder go to GitHub.
 * Each page is also served as Markdown at its URL plus `.md`.
 */
const files = import.meta.glob("../../../docs/*.md", { query: "?raw", import: "default", eager: true }) as Record<string, string>;

export type Doc = { slug: string; title: string; html: string; markdown: string };

const ORDER = ["README", "spaces", "layout", "cards", "agent-control"];

/** The Markdown copy of a page is served at the page's URL plus `.md`. */
export function markdownPath(slug: string): string {
  return slug ? `/docs/${slug}.md` : "/docs.md";
}

function rewrite(href: string, format: "html" | "markdown" = "html"): string {
  if (/^[a-z]+:/i.test(href) || href.startsWith("#")) return href;
  const [path, hash] = href.split("#");
  const anchor = hash ? `#${hash}` : "";
  const local = path.match(/^(?:\.\/)?([\w-]+)\.md$/);
  if (local) {
    const slug = local[1] === "README" ? "" : local[1];
    // Markdown copies are often read outside the site, so their links are absolute.
    if (format === "markdown") return new URL(markdownPath(slug), import.meta.env.SITE).href + anchor;
    return (slug ? `/docs/${slug}` : "/docs") + anchor;
  }
  if (path.startsWith("../")) return `${REPO}/blob/main/${path.slice(3)}${anchor}`;
  return `${REPO}/blob/main/docs/${path}${anchor}`;
}

const marked = new Marked({
  walkTokens(token) {
    if (token.type === "link") token.href = rewrite(token.href);
  },
});

/** Rewrites the links in Markdown text, leaving fenced code blocks alone. */
function rewriteMarkdown(text: string): string {
  return text
    .split(/(^```[\s\S]*?^```)/m)
    .map((part, index) => (index % 2 ? part : part.replace(/\]\(([^)\s]+)\)/g, (_, href) => `](${rewrite(href, "markdown")})`)))
    .join("");
}

export const docs: Doc[] = Object.entries(files)
  .map(([file, text]) => {
    const name = file.split("/").pop()!.replace(/\.md$/, "");
    const title = text.match(/^#\s+(.+)$/m)?.[1] ?? name;
    // The page prints its title in the layout, so the file's own heading is dropped.
    const body = text.replace(/^#\s+.+\n/m, "");
    return { slug: name === "README" ? "" : name, title, html: marked.parse(body, { async: false }) as string, markdown: rewriteMarkdown(text), name };
  })
  .sort((a, b) => ORDER.indexOf(a.name) - ORDER.indexOf(b.name))
  .map(({ slug, title, html, markdown }) => ({ slug, title, html, markdown }));

import type { APIRoute } from "astro";
import { docs, markdownPath } from "../lib/docs";
import { DOWNLOAD, REPO, REQUIREMENTS } from "../lib/site";

/** An index of the site for language models, in the llms.txt format (https://llmstxt.org). */
export const GET: APIRoute = ({ site }) => {
  const url = (path: string) => new URL(path, site).href;
  const pages = docs.map(doc => `- [${doc.slug ? doc.title : "Overview"}](${url(markdownPath(doc.slug))})`);
  const text = [
    "# Rune",
    "",
    "> Rune is a native Mac terminal that knows your repo and the coding agents running in it, such as Claude Code and Codex.",
    "",
    `Rune runs on ${REQUIREMENTS}. Each docs page below is the Markdown copy of a page under ${url("/docs")}.`,
    "",
    "## Docs",
    "",
    ...pages,
    "",
    "## Optional",
    "",
    `- [Source code](${REPO})`,
    `- [Download](${DOWNLOAD})`,
    `- [Changelog](${url("/changelog")})`,
    "",
  ].join("\n");
  return new Response(text, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
};

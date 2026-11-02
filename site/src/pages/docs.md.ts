import type { APIRoute } from "astro";
import { docs } from "../lib/docs";

/** The overview page as Markdown, at `/docs.md`. */
export const GET: APIRoute = () => {
  const doc = docs.find(item => !item.slug)!;
  return new Response(doc.markdown, { headers: { "Content-Type": "text/markdown; charset=utf-8" } });
};

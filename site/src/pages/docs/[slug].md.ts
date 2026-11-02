import type { APIRoute } from "astro";
import { docs } from "../../lib/docs";

/** Each docs page as Markdown, at `/docs/<slug>.md`. */
export function getStaticPaths() {
  return docs.filter(doc => doc.slug).map(doc => ({ params: { slug: doc.slug }, props: { markdown: doc.markdown } }));
}

export const GET: APIRoute = ({ props }) =>
  new Response(props.markdown, { headers: { "Content-Type": "text/markdown; charset=utf-8" } });

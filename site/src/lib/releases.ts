import { marked } from "marked";

/**
 * Release notes live on GitHub. They are fetched once per build, so the changelog
 * matches what was published. This runs at build time, never in the browser.
 */
const SOURCE = "https://api.github.com/repos/scmmishra/rune/releases?per_page=100";

type GitHubRelease = { tag_name: string; html_url: string; published_at: string; body: string | null; draft: boolean };

export type Release = { version: string; url: string; date: string; isoDate: string; html: string };

const headers: Record<string, string> = { Accept: "application/vnd.github+json" };
if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

const response = await fetch(SOURCE, { headers });
if (!response.ok) {
  throw new Error(`Could not fetch releases: ${response.status} ${response.statusText}`);
}

const dateFormat = new Intl.DateTimeFormat("en", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });

export const releases: Release[] = ((await response.json()) as GitHubRelease[])
  .filter(release => !release.draft)
  .map(release => ({
    version: release.tag_name,
    url: release.html_url,
    date: dateFormat.format(new Date(release.published_at)),
    isoDate: release.published_at.slice(0, 10),
    html: marked.parse(release.body ?? "", { async: false }),
  }));

export const latest = releases[0];

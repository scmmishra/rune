// @ts-check
import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://rune.shivam.dev",
  vite: {
    build: {
      // Vite inlines files under 4 KB as data URIs. A font must stay a file, so that
      // pages can preload it and its unicode-range can skip downloading it.
      assetsInlineLimit: file => (file.endsWith(".woff2") ? false : undefined),
    },
  },
});

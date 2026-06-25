import { resolve } from "node:path";
import { defineConfig, type Plugin } from "vite";

// In production, Cloudflare's asset serving maps /announcements -> announcements.html
// automatically. This mirrors that for `vite dev` and `vite preview`.
//
// /research          -> research.html      (the index, served directly by CF)
// /research/<slug>   -> research.html       in dev; in production CF has no matching
//                       static file for the nested path and falls back to the SPA
//                       handler (index.html), which detects the /research/ prefix and
//                       hands rendering to the same research entry script. The research
//                       module reads location.pathname, so a single entry serves both.
function cleanUrls(): Plugin {
  const middleware = (req: any, _res: any, next: () => void) => {
    const url = req.url ?? "";
    if (/^\/announcements(\?|$)/.test(url)) req.url = "/announcements.html";
    else if (/^\/compatibility(\?|$)/.test(url)) req.url = "/compatibility.html";
    else if (/^\/research(\/|\?|$)/.test(url)) req.url = "/research.html";
    else if (/^\/v2(\?|$)/.test(url)) req.url = "/v2.html";
    next();
  };
  return {
    name: "clean-urls",
    configureServer(server) {
      server.middlewares.use(middleware);
    },
    configurePreviewServer(server) {
      server.middlewares.use(middleware);
    },
  };
}

export default defineConfig({
  plugins: [cleanUrls()],
  // ANNOUNCEMENTS.md is imported from the repo root (one level above this Vite root).
  server: { fs: { allow: [resolve(__dirname, "..")] } },
  build: {
    target: "es2020",
    cssMinify: true,
    assetsInlineLimit: 0,
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        compatibility: resolve(__dirname, "compatibility.html"),
        announcements: resolve(__dirname, "announcements.html"),
        research: resolve(__dirname, "research.html"),
        v2: resolve(__dirname, "v2.html"),
      },
    },
  },
});

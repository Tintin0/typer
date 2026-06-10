import { resolve } from "node:path";
import { defineConfig, type Plugin } from "vite";

// In production, Cloudflare's asset serving maps /announcements -> announcements.html
// automatically. This mirrors that for `vite dev` and `vite preview`.
function cleanUrls(): Plugin {
  const middleware = (req: any, _res: any, next: () => void) => {
    if (/^\/announcements(\?|$)/.test(req.url ?? "")) req.url = "/announcements.html";
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
        announcements: resolve(__dirname, "announcements.html"),
      },
    },
  },
});

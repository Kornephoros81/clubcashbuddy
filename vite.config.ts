import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import path from "path";
import { VitePWA } from "vite-plugin-pwa";
import { execSync } from "child_process";

let buildId = "dev";
try {
  buildId = execSync("git rev-parse --short HEAD").toString().trim();
} catch {
  buildId = String(Date.now());
}

export default defineConfig({
  base: "/",
  define: {
    "import.meta.env.VITE_BUILD_ID": JSON.stringify(buildId),
  },
  build: {
    outDir: "dist",
    assetsDir: "assets",
    manifest: true,
    rollupOptions: {
      output: {
        entryFileNames: `assets/[name]-[hash].js`,
        chunkFileNames: `assets/[name]-[hash].js`,
        assetFileNames: `assets/[name]-[hash][extname]`,
      },
    },
  },
  plugins: [
    vue(),
    VitePWA({
      registerType: "autoUpdate",
      disableManifestGeneration: true,
      workbox: {
        globPatterns: ["**/*.{js,css,html,ico,png,svg,webmanifest}"],
        cleanupOutdatedCaches: true,
        clientsClaim: true,
        skipWaiting: true,

        // SPA-Fallback darf .well-known NIE anfassen
        navigateFallbackDenylist: [
          /^\/assets\//,
          /^\/favicon/,
          /^\/manifest/,
          /^\/service-worker/,
          /^\/robots\.txt/,
          /^\/\.well-known\//, // ← hinzugefügt
        ],

        runtimeCaching: [
          // .well-known: immer Netzwerk, nie Cache
          {
            urlPattern: /^https?:\/\/[^/]+\/\.well-known\/assetlinks\.json$/,
            handler: "NetworkOnly",
            options: { cacheName: "no-cache" },
          },

          // Assets wie gehabt
          {
            urlPattern: /^https?:\/\/.*\/(js|css|png|jpg|svg|ico|webmanifest)$/,
            handler: "CacheFirst",
            options: {
              cacheName: "assets-cache",
              expiration: { maxEntries: 50, maxAgeSeconds: 60 * 60 * 24 * 30 },
            },
          },

          // API wie gehabt
          {
            urlPattern: /^https?:\/\/.*\/api\//,
            handler: "NetworkFirst",
            options: {
              cacheName: "api-cache",
              networkTimeoutSeconds: 3,
              expiration: { maxEntries: 30, maxAgeSeconds: 60 * 60 * 24 },
            },
          },
        ],
      },
    }),
    // ✅ sicheres Copy-Plugin (lazy import)
    {
      name: "copy-manifest",
      async buildStart() {
        // Dynamischer Import nur bei Node verfügbar
        try {
          const { existsSync, mkdirSync, copyFileSync } = await import("fs");
          const src = "public/manifest.webmanifest";
          const dest = "dist/manifest.webmanifest";
          if (existsSync(src)) {
            mkdirSync("dist", { recursive: true });
            copyFileSync(src, dest);
            console.log(`✅ Copied manifest (${src} → ${dest})`);
          } else {
            console.warn(`⚠️ Manifest not found at ${src}`);
          }
        } catch (err) {
          console.warn(
            "⚠️ Manifest copy skipped – fs unavailable in this environment"
          );
        }
      },
    },
  ],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
});

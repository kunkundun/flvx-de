import path from "path";

import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";

/**
 * 面板挂载路径在运行期由后端注入 index.html（window.BASE_URL）：
 * 构建产物里写占位符 /__FLVX_BASE__/，paneld 启动时替换成真实前缀，
 * 因此换路径不需要重新构建前端。dev 模式仍用根路径。
 */
const BASE_PLACEHOLDER = "/__FLVX_BASE__/";

export default defineConfig(({ command }) => ({
  plugins: [
    react(),
    VitePWA({
      registerType: "prompt",
      injectRegister: "auto",
      includeAssets: ["favicon.ico", "apple-touch-icon.png"],
      manifest: {
        name: "FLVX",
        short_name: "FLVX",
        description: "FLVX forwarding management panel",
        theme_color: "#2563eb",
        background_color: "#f6f7fb",
        display: "standalone",
        start_url: "./",
        scope: "./",
        icons: [
          {
            src: "pwa-192x192.png",
            sizes: "192x192",
            type: "image/png",
          },
          {
            src: "pwa-512x512.png",
            sizes: "512x512",
            type: "image/png",
          },
          {
            src: "pwa-maskable-512x512.png",
            sizes: "512x512",
            type: "image/png",
            purpose: "maskable",
          },
        ],
      },
      workbox: {
        navigateFallback: "index.html",
        cleanupOutdatedCaches: true,
        maximumFileSizeToCacheInBytes: 5 * 1024 * 1024,
      },
    }),
  ],
  base: command === "build" ? BASE_PLACEHOLDER : "/",
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  server: {
    port: 3000,
    host: "0.0.0.0",
  },
  build: {
    outDir: "dist",
    sourcemap: false,
    minify: false,
    rollupOptions: {
      treeshake: false,
    },
  },
}));

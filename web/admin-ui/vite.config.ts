import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api/control-plane": {
        target: "http://127.0.0.1:8081",
        changeOrigin: true,
        rewrite: (requestPath) => requestPath.replace(/^\/api\/control-plane/, ""),
      },
      "/api/gateway": {
        target: "http://127.0.0.1:8080",
        changeOrigin: true,
        rewrite: (requestPath) => requestPath.replace(/^\/api\/gateway/, ""),
      },
      "/api/mock-provider": {
        target: "http://127.0.0.1:18080",
        changeOrigin: true,
        rewrite: (requestPath) => requestPath.replace(/^\/api\/mock-provider/, ""),
      },
    },
  },
  test: {
    environment: "jsdom",
    fileParallelism: false,
    setupFiles: "./src/test/setup.ts",
  },
});

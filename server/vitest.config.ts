import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-plugin";

export default defineConfig({
  // Tests run without the AI binding or Anthropic key (no network, no cost).
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.test.jsonc" } })],
});

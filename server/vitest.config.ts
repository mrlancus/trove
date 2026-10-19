import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-plugin";

export default defineConfig({
  // Tests run without the AI binding or Anthropic key (no network, no cost).
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.test.jsonc" } })],
  // The first test in each file boots workerd; give slower machines headroom.
  test: { testTimeout: 20_000 },
});

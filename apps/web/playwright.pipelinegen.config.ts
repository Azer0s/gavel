// The browser specs as pipelinegen's batch task runs them: the batch starts
// the server itself, once per spec file, on the port it chose, so this
// config takes gavel's own and drops its webServer.
import { defineConfig } from "@playwright/test";
import gavel from "./playwright.config";

const port = process.env.E2E_SERVER_PORT ?? "3333";

export default defineConfig({
  ...gavel,
  webServer: undefined,
  reporter: [["list"], ["json", { outputFile: process.env.PLAYWRIGHT_JSON ?? "playwright.json" }]],
  use: { ...gavel.use, baseURL: `http://localhost:${port}` },
});

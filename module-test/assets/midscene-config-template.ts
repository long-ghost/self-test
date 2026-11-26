// Midscene Test 项目配置模板（l4-run 每轮复制到 runs/<runId>/midscene.config.ts）
// 只注册官方 Web Node；不加载业务仓库自定义 Node（v1 限制）。
// 依赖：@midscene/test @midscene/web playwright
// 适配 @midscene/test ^1.18：项目级 Browser + 文件级 Page/Agent（defineProjectSetup + defineFileSetup）。
import { fileURLToPath } from 'node:url';
import type { NodeExecutionContext } from '@midscene/test';
import {
  defineFileSetup,
  defineProjectSetup,
  defineTestProject,
} from '@midscene/test/config';
import { createMidsceneNodes } from '@midscene/test/midscene';
import { PlaywrightAgent } from '@midscene/web/playwright/agent';
import { config as loadEnv } from 'dotenv';
import { chromium, type Browser, type Page } from 'playwright';

loadEnv({ path: fileURLToPath(new URL('.env', import.meta.url)) });

interface ProjectContext {
  browser: Browser;
}

interface FileContext {
  page: Page;
  agent?: PlaywrightAgent;
}

// 项目级：整个项目只启一个共享 Browser（headless 可用 HEADLESS=false 覆盖）。
const projectSetup = defineProjectSetup<ProjectContext>({
  name: 'web',
  async setup({ env, onTeardown }) {
    const browser = await chromium.launch({ headless: env.HEADLESS !== 'false' });
    onTeardown(() => browser.close());
    return { browser };
  },
});

// 文件级：每份 YAML 独立 BrowserContext / Page / Agent；Cookie 从进程环境读取，不落盘。
const fileSetup = defineFileSetup<FileContext, ProjectContext>({
  name: 'web-file',
  async setup({ projectContext, signal, onTeardown }) {
    if (!projectContext) throw new Error('Web project setup did not create a browser.');
    const browserContext = await projectContext.browser.newContext();
    onTeardown(() => browserContext.close());
    signal.throwIfAborted();
    const page = await browserContext.newPage();
    // 用例里用相对路径时，由 runner 注入 L4_BASE_URL；作为 gotoUrl 的 baseUrl 兜底。
    if (process.env.L4_BASE_URL) {
      await page.goto(process.env.L4_BASE_URL).catch(() => {});
    }
    const context: FileContext = { page };
    onTeardown(async () => {
      await context.agent?.destroy();
    });
    return context;
  },
});

const getAgent = ({ context }: NodeExecutionContext<unknown, FileContext>) => {
  context.agent ??= new PlaywrightAgent(context.page, {
    testRunner: { getEnv: () => process.env, getBaseUrl: () => process.env.L4_BASE_URL || 'http://localhost:3000' },
    ...(process.env.L4_CACHE_ID ? {
      cache: {
        id: process.env.L4_CACHE_ID,
        strategy: (process.env.L4_CACHE_STRATEGY as 'read-only'|'read-write'|'write-only') || 'read-only',
        cacheDir: process.env.L4_CACHE_DIR,
      },
    } : {}),
  });
  return context.agent;
};

export default defineTestProject<FileContext, ProjectContext>({
  projects: [
    {
      name: 'web',
      setup: projectSetup,
      fileSetup,
      files: { include: ['cases/**/*.{yaml,yml}'] },
    },
  ],
  // PlaywrightAgent 的 getTestRunnerNodeDefinitions() 含 aiAct/aiAssert/aiWaitFor 与
  // gotoUrl/setCookies/clearCookies/setViewportSize/wait 等官方 Web Node。
  nodes: createMidsceneNodes<FileContext>({
    agentClass: PlaywrightAgent,
    getAgent,
  }),
  // AI 抖动不静默重试；需要重跑时由 l4-run -RerunFlaky 显式执行并保留两轮证据。
  test: { maxConcurrentFiles: 1, bail: 1, testTimeout: 120_000 },
});

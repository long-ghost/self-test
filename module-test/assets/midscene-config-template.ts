// Midscene Test 项目配置模板（l4-run 每轮复制到 runs/<runId>/midscene.config.ts）
// 只注册官方 Web Node；不加载业务仓库自定义 Node（v1 限制）。
// 依赖：@midscene/test @midscene/web playwright
import {
  defineProjectSetup,
  defineTestProject,
} from '@midscene/test/config';
import { createMidsceneNodes } from '@midscene/test/midscene';
import { createPlaywrightNodes } from '@midscene/test/playwright';
import { PlaywrightAgent } from '@midscene/web/playwright';
import { chromium, type Browser, type Page } from 'playwright';

interface ProjectContext {
  browser: Browser;
  page: Page;
  agent?: PlaywrightAgent;
}

const midsceneNodes = createMidsceneNodes<ProjectContext>({
  agentClass: PlaywrightAgent,
  getAgent: ({ context }) => {
    context.agent ??= new PlaywrightAgent(context.page);
    return context.agent;
  },
});

const playwrightNodes = createPlaywrightNodes<ProjectContext>({
  getPage: ({ context }) => context.page,
  // Cookie 通过 cookiesEnv 引用，从进程环境读取，不落盘
  getEnv: () => process.env,
  // 用例里用相对路径时，由 runner 注入 L4_BASE_URL
  getBaseUrl: () => process.env.L4_BASE_URL || 'http://localhost:3000',
});

const playwrightSetup = defineProjectSetup<ProjectContext>({
  name: 'playwright',
  platform: 'web',
  async setup({ onTeardown }) {
    const browser = await chromium.launch({ headless: true });
    onTeardown(() => browser.close());
    const browserContext = await browser.newContext();
    const page = await browserContext.newPage();
    const context: ProjectContext = { browser, page };
    onTeardown(async () => {
      await context.agent?.destroy();
    });
    return context;
  },
});

export default defineTestProject<ProjectContext>({
  projects: [
    {
      name: 'web',
      platform: 'web',
      setup: playwrightSetup,
      files: { include: ['cases/**/*.{yaml,yml}'] },
      // AI 抖动不静默重试；需要重跑时由 l4-run -RerunFlaky 显式执行并保留两轮证据
      retry: 0,
    },
  ],
  nodes: [...midsceneNodes, ...playwrightNodes],
  test: {
    maxConcurrency: 1,
    testTimeout: 120_000,
  },
  output: {
    reportFormat: 'single-html',
  },
});

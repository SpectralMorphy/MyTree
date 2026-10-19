const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require(process.argv[2] || 'playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const svg = await fs.readFile(path.join(root, 'assets/tree-mark.svg'), 'utf8');
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({ deviceScaleFactor: 1 });
    for (const [file, size, maskable] of [
      ['assets/tree-mark.png', 512, false],
      ['web/favicon.png', 32, false],
      ['web/icons/Icon-192.png', 192, false],
      ['web/icons/Icon-512.png', 512, false],
      ['web/icons/Icon-maskable-192.png', 192, true],
      ['web/icons/Icon-maskable-512.png', 512, true],
    ]) {
      await page.setViewportSize({ width: size, height: size });
      const image = maskable ? svg.replace('rx="112"', 'rx="0"') : svg;
      await page.setContent(`<style>html,body{margin:0;width:100%;height:100%;overflow:hidden}svg{display:block;width:100%;height:100%}</style>${image}`);
      await page.screenshot({ path: path.join(root, file), omitBackground: true });
    }
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

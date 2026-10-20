const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require(process.argv[2] || 'playwright');

// Tab favicon only: drop the rounded paper frame and the halo, then scale the
// tree to the icon. App icons and the in-app mark keep the framed artwork.
function tabMark(svg) {
  return svg
    .replace(/\r?\n\s*<rect width="512" height="512" rx="112" fill="url\(#paper\)"\/>/, '')
    .replace(/\r?\n\s*<circle cx="256" cy="235" r="159" fill="#D9E9CD"\/>/, '');
}

async function croppedTabMark(page, svg) {
  const mark = tabMark(svg);
  await page.setViewportSize({ width: 512, height: 512 });
  await page.setContent(`<style>html,body{margin:0}</style>${mark}`);
  const box = await page.evaluate(() => {
    const node = document.querySelector('svg');
    const bounds = node.getBBox();
    return { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height };
  });
  // Trunk and ground strokes extend past the fill bounds.
  const stroke = 12;
  const content = Math.max(box.width, box.height) + stroke * 2;
  const pad = content * 0.04;
  const side = content + pad * 2;
  const x = box.x - stroke - (side - (box.width + stroke * 2)) / 2;
  const y = box.y - stroke - (side - (box.height + stroke * 2)) / 2;
  return mark.replace(
    'viewBox="0 0 512 512"',
    `viewBox="${x.toFixed(2)} ${y.toFixed(2)} ${side.toFixed(2)} ${side.toFixed(2)}"`,
  );
}

(async () => {
  const root = path.resolve(__dirname, '..');
  const svg = await fs.readFile(path.join(root, 'assets/tree-mark.svg'), 'utf8');
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({ deviceScaleFactor: 1 });
    const favicon = await croppedTabMark(page, svg);
    for (const [file, size, maskable, image] of [
      ['assets/tree-mark.png', 512, false, svg],
      ['web/favicon.png', 64, false, favicon],
      ['web/icons/Icon-192.png', 192, false, svg],
      ['web/icons/Icon-512.png', 512, false, svg],
      ['web/icons/Icon-maskable-192.png', 192, true, svg],
      ['web/icons/Icon-maskable-512.png', 512, true, svg],
    ]) {
      await page.setViewportSize({ width: size, height: size });
      const framed = maskable ? image.replace('rx="112"', 'rx="0"') : image;
      await page.setContent(`<style>html,body{margin:0;width:100%;height:100%;overflow:hidden}svg{display:block;width:100%;height:100%}</style>${framed}`);
      await page.screenshot({ path: path.join(root, file), omitBackground: true });
    }
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

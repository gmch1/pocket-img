// One SVG master -> macOS AppIcon, fnOS icons and multi-resolution ICO.
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const temporary = await mkdtemp(resolve(tmpdir(), 'pocketimg-brand-'));
let browser;
try {
  browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
  const svg = await readFile(resolve(root, 'frontend/public/favicon.svg'), 'utf8');
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:100vw;height:100vh}</style>${svg}`);
  const master = resolve(temporary, 'master.png');
  await page.screenshot({ path: master, omitBackground: true });
  const generated = spawnSync('go', ['run', './scripts/generate_macos_app_icons.go', master,
    'macos/PocketIMGShot/Assets.xcassets/AppIcon.appiconset'], { cwd: root, stdio: 'inherit' });
  if (generated.status !== 0) throw new Error('macOS icon generation failed');
  const sizes = [16, 32, 48, 64, 128, 256];
  const pngs = [];
  for (const size of sizes) {
    await page.setViewportSize({ width: size, height: size });
    const png = await page.screenshot({ omitBackground: true });
    pngs.push(png);
    if (size === 64 || size === 256) {
      await writeFile(resolve(root, `deploy/fnos/pocket-img/app/ui/images/icon_${size}.png`), png);
    }
  }
  // ICO directory followed by PNG-encoded entries; 0 denotes 256 pixels.
  const header = Buffer.alloc(6 + sizes.length * 16);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(sizes.length, 4);
  let offset = header.length;
  sizes.forEach((size, index) => {
    const entry = 6 + index * 16;
    header[entry] = header[entry + 1] = size === 256 ? 0 : size;
    header.writeUInt16LE(1, entry + 4);
    header.writeUInt16LE(32, entry + 6);
    header.writeUInt32LE(pngs[index].length, entry + 8);
    header.writeUInt32LE(offset, entry + 12);
    offset += pngs[index].length;
  });
  await writeFile(resolve(root, 'frontend/public/favicon.ico'), Buffer.concat([header, ...pngs]));
  console.log('Generated macOS, fnOS and favicon assets.');
} finally {
  await browser?.close();
  await rm(temporary, { recursive: true, force: true });
}

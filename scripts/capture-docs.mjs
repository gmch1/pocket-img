// Real browser captures against an isolated, disposable PocketIMG instance.
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const binary = resolve(root, process.env.POCKETIMG_BINARY || 'dist/phone-image-host-linux-amd64');
const data = await mkdtemp(resolve(tmpdir(), 'pocketimg-docs-'));
const output = resolve(root, 'docs/assets');
const probe = createServer();
await new Promise((done) => probe.listen(0, '127.0.0.1', done));
const port = probe.address().port;
await new Promise((done) => probe.close(done));
const address = `http://127.0.0.1:${port}`;
const env = { ...process.env, PIH_DATA_DIR: data, PIH_ADDR: `127.0.0.1:${port}`,
  PIH_TOKEN: '', PIH_TOKENS: '', PIH_TOKENS_FILE: '', PIH_ADMIN_SPACE_ID: 'demo',
  PIH_FNOS_SOCKET: '', PIH_TUNNEL_ENABLED: 'false', PIH_COOKIE_SECURE: 'false' };
let server;
let browser;
try {
  const init = spawnSync(binary, ['init'], { env, encoding: 'utf8' });
  if (init.status !== 0) throw new Error(`Initialization failed: ${init.stderr}`);
  const token = JSON.parse(await readFile(resolve(data, 'tokens.json'), 'utf8')).demo;
  server = spawn(binary, [], { env, stdio: 'ignore' });
  server.on('error', () => {});
  let healthy = false;
  for (let i = 0; i < 100; i++) {
    try { healthy = (await fetch(`${address}/healthz`)).ok; } catch {}
    if (healthy) break;
    await new Promise((done) => setTimeout(done, 100));
  }
  if (!healthy) throw new Error('Screenshot backend did not start');
  browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
  const page = await browser.newPage({ viewport: { width: 1280, height: 780 }, deviceScaleFactor: 2, locale: 'zh-CN', timezoneId: 'Asia/Shanghai', colorScheme: 'light' });
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto(address);
  await page.getByLabel('Token', { exact: true }).fill(token);
  await page.getByRole('button', { name: '进入', exact: true }).click();
  await page.locator('.gallery-shell').waitFor();
  // Original geometric/editorial sample sheets. These are gallery contents,
  // never a replacement or overlay for the real application's interface.
  await page.evaluate(async () => {
    const themes = [
      ['#e4e8de', '#265746', '#b1c3a5', 'FIELD NOTES', '留一点空间'],
      ['#f0ded1', '#904d38', '#d6a881', 'WARM LIGHT', '日常的一束光'],
      ['#dce3ed', '#3e5476', '#a1b7d0', 'BLUE HOUR', '安静的片刻'],
      ['#eee8d9', '#786747', '#c4b68d', 'STUDIO / 04', '想法，随手记下'],
      ['#e3dedf', '#665569', '#b3a0b2', 'FORM & SPACE', '看见不同的形状'],
      ['#dfe9e4', '#3a6657', '#9fbdad', 'SMALL THINGS', '收集生活的细节'],
    ];
    const sheets = [];
    for (let i = 0; i < 18; i++) {
      const [bg, ink, soft, title, subtitle] = themes[(i + Math.floor(i / 6) * 2) % themes.length];
      const canvas = document.createElement('canvas'); canvas.width = 960; canvas.height = 720;
      const c = canvas.getContext('2d');
      c.fillStyle = bg; c.fillRect(0, 0, 960, 720);
      c.fillStyle = ink; c.font = '18px sans-serif'; c.fillText(`POCKETIMG  /  SAMPLE ${String(i + 1).padStart(2, '0')}`, 48, 52);
      const shape = (i + Math.floor(i / 6)) % 3;
      if (shape === 0) {
        c.fillStyle = soft; c.beginPath(); c.arc(740, 220, 148, 0, Math.PI * 2); c.fill();
        c.fillStyle = ink; c.fillRect(520, 250, 280, 280);
        c.fillStyle = bg; c.beginPath(); c.arc(520, 250, 130, 0, Math.PI * 2); c.fill();
      } else if (shape === 1) {
        for (let j = 0; j < 5; j++) {
          c.fillStyle = j % 2 ? ink : soft;
          c.beginPath(); c.roundRect(485 + j * 60, 170 + j * 38, 50, 310 - j * 24, 25); c.fill();
        }
      } else {
        for (let j = 0; j < 3; j++) {
          c.strokeStyle = j === 1 ? ink : soft; c.lineWidth = 42;
          c.beginPath(); c.arc(700, 330, 80 + j * 55, Math.PI, Math.PI * 2); c.stroke();
          c.beginPath(); c.moveTo(620 - j * 55, 330); c.lineTo(620 - j * 55, 500); c.stroke();
        }
      }
      c.fillStyle = ink; c.font = 'bold 38px sans-serif';
      const words = title.split(' '); words.forEach((word, index) => c.fillText(word, 48, 270 + index * 48));
      c.font = '23px sans-serif'; c.fillText(subtitle, 48, 470);
      c.globalAlpha = 0.65; c.font = '16px sans-serif'; c.fillText('原创几何演示样张 · 非产品界面', 48, 670); c.globalAlpha = 1;
      sheets.push(await new Promise((done) => canvas.toBlob(done, 'image/png')));
    }
    for (const [i, blob] of sheets.entries()) {
      const form = new FormData(); form.append('file', blob, `sample-${i + 1}.png`);
      const response = await fetch('/api/images', { method: 'POST', body: form });
      if (!response.ok) throw new Error(`Sample upload failed: ${response.status}`);
    }
  });
  await page.reload();
  await page.waitForFunction(() => document.querySelectorAll('.image-card img').length === 18 && [...document.querySelectorAll('.image-card img')].every((img) => img.complete && img.naturalWidth > 0));
  await page.evaluate(() => document.fonts.ready);
  await page.locator('.image-card').nth(2).hover();
  await page.waitForTimeout(700);
  await mkdir(output, { recursive: true });
  await page.screenshot({ path: resolve(output, 'gallery.png') });
  await page.locator('.image-card').nth(2).click();
  await page.getByRole('dialog', { name: '媒体预览' }).waitFor();
  await page.waitForFunction(() => { const img = document.querySelector('.preview-shell > img'); return img?.complete && img.naturalWidth > 0; });
  await page.mouse.move(0, 0);
  await page.waitForTimeout(300);
  await page.screenshot({ path: resolve(output, 'preview.png') });
  await page.getByRole('button', { name: '关闭预览' }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  if (!await page.locator('.brand').isVisible()) throw new Error('Mobile brand not visible');
  if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw new Error('Mobile horizontal overflow');
  if (errors.length) throw new Error(errors.join('\n'));
  console.log('Captured gallery.png and preview.png from the live backend; desktop and mobile checks passed.');
} finally {
  if (browser) await browser.close();
  if (server?.pid && server.exitCode === null) {
    server.kill('SIGTERM');
    await new Promise((done) => server.once('exit', done));
  }
  await rm(data, { recursive: true, force: true });
}

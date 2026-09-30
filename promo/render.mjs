// Renders promo/index.html. `node render.mjs beats OUT` writes one PNG per
// beat; `node render.mjs frames OUT` writes every subframe (4 per frame at
// 60 fps) for ffmpeg to blend.
import { chromium } from "playwright";  // npm i playwright
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const [mode = "beats", out = "out", workers = "4"] = process.argv.slice(2);
const here = path.dirname(fileURLToPath(import.meta.url));
const page_url = "file://" + path.join(here, "index.html");
fs.mkdirSync(out, { recursive: true });

const FPS = 60, SUB = 4, T = 14;
const jobs = mode === "beats"
  ? Array.from({ length: 28 }, (_, i) => ({ t: i * 0.5, name: `beat-${String(i).padStart(2, "0")}.png` }))
  : Array.from({ length: T * FPS * SUB }, (_, i) => ({
      // Subframes spread evenly across each frame's 1/60 s, centred on it.
      t: (Math.floor(i / SUB) + ((i % SUB) + 0.5) / SUB - 0.5) / FPS,
      name: `sub-${String(i).padStart(5, "0")}.png`,
    }));

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
let next = 0;
await Promise.all(Array.from({ length: Number(workers) }, async () => {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1440 }, deviceScaleFactor: 1 });
  await page.goto(page_url);
  await page.evaluate(() => window.ready);
  const cdp = await page.context().newCDPSession(page);
  while (next < jobs.length) {
    const job = jobs[next++];
    const file = path.join(out, job.name);
    if (fs.existsSync(file)) continue;
    await page.evaluate(t => window.seek(t), job.t);
    const { data } = await cdp.send("Page.captureScreenshot", { format: "png" });
    fs.writeFileSync(file, Buffer.from(data, "base64"));
  }
}));
await browser.close();

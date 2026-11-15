// Sends a black snap to everyone in the 🔥 (streaks) shortcut on Snapchat Web,
// using the session saved by `node login.js` (./chrome-profile plus the
// cookie jar ./cookies.json; see session.js for why both are needed).
//
// Flow (verified by hand on 2026-11-10):
//   1. camera button            button.qJKfS
//   2. shutter (short tap)      button.fE2D5              -> photo preview
//   3. "Send to"                button, text "Send to"
//   4. 🔥 shortcut              button.c47Sk, text "🔥"
//   5. "Select" (select all)    button.Y7u8A, text "Select"
//   6. "Send"                   button[type=submit], text "Send"
//
// Snapchat's class names are obfuscated and change between builds, so every
// step matches on text / title / type first and only uses the class as a
// fallback.
//
// There is no webcam on the server: Chrome is given a fake camera that plays
// a generated black frame, so the snap is always a plain black picture.
//
// Env:
//   ONLY_STREAKS=1   select only the rows that show a streak count instead of
//                    the whole 🔥 shortcut (which may include non-streak friends)
//   DRY_RUN=1        do everything except clicking the final Send
//   DISCORD_WEBHOOK  failure alerts (defaults to the URL in ./webhook, if any;
//                    set it empty to disable)
//
// Exit codes: 0 sent, 1 failed, 2 not logged in (run `node login.js`).

import puppeteer from "puppeteer";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { restoreCookies, saveCookies } from "./session.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const USER_DATA_DIR = path.join(__dirname, "chrome-profile");
const BLACK_Y4M = path.join(__dirname, "black.y4m");
const LOG_DIR = path.join(__dirname, "logs");

const APP_URL = "https://www.snapchat.com/web/";
const STEP_TIMEOUT = 20_000;
const RUN_TIMEOUT = 3 * 60_000;

const ONLY_STREAKS = process.env.ONLY_STREAKS === "1";
const DRY_RUN = process.env.DRY_RUN === "1";
// DISCORD_WEBHOOK= (set but empty) disables alerts.
const WEBHOOK = process.env.DISCORD_WEBHOOK ?? readFileOrEmpty(path.join(__dirname, "webhook"));

class NotLoggedInError extends Error {}

function readFileOrEmpty(file) {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (msg) => console.log(`[${new Date().toISOString()}] ${msg}`);

// A single black 640x480 frame in Y4M format; Chrome loops it as the camera.
function ensureBlackFrame() {
  if (fs.existsSync(BLACK_Y4M)) return;
  const w = 640, h = 480;
  const header = Buffer.from(`YUV4MPEG2 W${w} H${h} F30:1 Ip A1:1 C420jpeg\nFRAME\n`);
  const y = Buffer.alloc(w * h, 16); // video black
  const uv = Buffer.alloc((w / 2) * (h / 2) * 2, 128); // no colour
  fs.writeFileSync(BLACK_Y4M, Buffer.concat([header, y, uv]));
}

// Waits for a visible <button> matching any of the given criteria and returns it.
async function findButton(page, { text, title, cls, type }, timeout = STEP_TIMEOUT) {
  const handle = await page.waitForFunction(
    ({ text, title, cls, type }) => {
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== "hidden";
      };
      const buttons = [...document.querySelectorAll("button")].filter(visible);
      const norm = (s) => (s || "").trim().toLowerCase();
      return (
        buttons.find(
          (b) =>
            (text == null || norm(b.innerText) === norm(text)) &&
            (title == null || b.title === title) &&
            (type == null || b.type === type) &&
            (text != null || title != null) // need at least one stable criterion
        ) ||
        (cls ? buttons.find((b) => b.classList.contains(cls) && (type == null || b.type === type)) : null) ||
        null
      );
    },
    { timeout },
    { text: text ?? null, title: title ?? null, cls: cls ?? null, type: type ?? null }
  );
  return handle.asElement();
}

// Clicks a button and waits for the next screen (`expect`) to show up,
// retrying a few times: clicks that land while Snapchat is still animating
// a panel in are silently ignored.
async function clickUntil(page, target, expect, attempts = 3, expectTimeout = 5000) {
  for (let i = 1; ; i++) {
    await sleep(800);
    const button = await findButton(page, target, i === 1 ? STEP_TIMEOUT : 2000).catch(() => null);
    if (!button) {
      // The target is gone, so the earlier click probably worked and the
      // next screen is just slow.
      return findButton(page, expect, STEP_TIMEOUT);
    }
    await button.click();
    try {
      return await findButton(page, expect, expectTimeout);
    } catch (err) {
      if (i >= attempts) throw err;
      log(`  click on ${JSON.stringify(target)} had no effect yet, retrying (${i}/${attempts - 1})`);
    }
  }
}

async function step(n, label, fn) {
  log(`${n}/6 ${label}`);
  try {
    return await fn();
  } catch (err) {
    throw new Error(`step ${n} (${label}) failed: ${err.message}`);
  }
}

// Logged-out users get redirected to the marketing site / accounts login,
// which neither contains "/login" in the URL reliably nor has
// input[name=username], so look for the app itself instead.
async function checkLoggedIn(page) {
  const state = await page
    .waitForFunction(
      () => {
        if (document.querySelector('[aria-label="Friends feed"], button.qJKfS')) return "in";
        const loginBtn = [...document.querySelectorAll("button")].some((b) =>
          /^(log in|next)$/i.test(b.innerText.trim())
        );
        if (location.hostname.startsWith("accounts.") || loginBtn) return "out";
        return null;
      },
      { timeout: 45_000 }
    )
    .then((h) => h.jsonValue())
    .catch(() => "unknown");

  if (state === "out") throw new NotLoggedInError(`Not logged in (landed on ${page.url()}). Run \`node login.js\`.`);
  if (state !== "in") throw new Error(`Snapchat Web did not load (url: ${page.url()})`);
}

async function sendSnap(page) {
  log(`Restored ${await restoreCookies(page)} cookies from cookies.json.`);
  await page.goto(APP_URL, { waitUntil: "domcontentloaded", timeout: 60_000 });
  await checkLoggedIn(page);
  log("Logged in.");
  await saveCookies(page); // keep the jar fresh if Snapchat rotated tokens

  await step(1, "open camera", async () => {
    // The camera sometimes switches itself back off when it's opened while
    // the app is still booting, so (re)click until the stream is live,
    // which is when the "Turn off camera" button appears.
    await sleep(2000);
    for (let i = 1; ; i++) {
      const open = await findButton(page, { cls: "qJKfS" }, 5000).catch(() => null);
      if (open) await open.click();
      const live = await findButton(page, { title: "Turn off camera" }, 15_000).catch(() => null);
      if (live) break;
      if (i >= 3) throw new Error("camera never started");
      log(`  camera not live yet, retrying (${i}/2)`);
    }
  });

  await step(2, "take photo", async () => {
    await sleep(1500); // let the stream deliver a few frames
    // Short press = photo (holding records video).
    await clickUntil(page, { cls: "fE2D5" }, { text: "Send to" }, 1);
  });

  await step(3, 'open "Send to"', async () => {
    await clickUntil(page, { text: "Send to" }, { text: "🔥", cls: "c47Sk" });
  });

  await step(4, "open 🔥 shortcut", async () => {
    await clickUntil(page, { text: "🔥", cls: "c47Sk" }, { text: "Select", cls: "Y7u8A" });
    await sleep(1000); // let the list render
  });

  const recipients = await step(5, ONLY_STREAKS ? "select streak friends" : "select all", async () => {
    const selectBtn = await findButton(page, { text: "Select", cls: "Y7u8A" });
    // Friend rows are the <li>s of the list that holds the "Select" header;
    // streak rows show "<count> 🔥".
    const rows = await selectBtn.evaluateHandle((b) => {
      const list = b.closest("ul, ol") || b.closest("li")?.parentElement;
      return [...(list?.children || [])].filter((li) => li !== b.closest("li"));
    });
    const rowHandles = [...(await rows.getProperties()).values()].map((h) => h.asElement()).filter(Boolean);
    const picked = [];
    if (!ONLY_STREAKS) {
      await selectBtn.click();
      for (const li of rowHandles) picked.push(await li.evaluate((e) => e.innerText.split("\n")[0].trim()));
    } else {
      for (const li of rowHandles) {
        const text = await li.evaluate((e) => e.innerText);
        if (!/\d+\s*🔥/.test(text)) continue;
        await li.evaluate((e) => e.scrollIntoView({ block: "center" }));
        await sleep(200);
        await li.click();
        await sleep(200);
        picked.push(text.split("\n")[0].trim());
      }
    }
    if (!picked.length) throw new Error("no recipients found in the 🔥 list");
    await sleep(1000);
    return picked;
  });

  const sendBtn = await findButton(page, { text: "Send", type: "submit", cls: "TYX6O" });
  log(`Recipients (${recipients.length}): ${recipients.join(", ")}`);

  if (DRY_RUN) {
    log("DRY_RUN=1, not sending.");
    return;
  }

  await step(6, "send", async () => {
    await sendBtn.click();
    // On success the recipient panel and preview close and the camera
    // button comes back.
    await page.waitForFunction(
      () =>
        ![...document.querySelectorAll("button")].some(
          (b) => b.type === "submit" && b.innerText.trim() === "Send"
        ) && !document.querySelector("#snap-preview-container"),
      { timeout: STEP_TIMEOUT }
    );
  });
  log("Snap sent.");
  await saveCookies(page);
}

async function notify(message) {
  if (!WEBHOOK) return;
  try {
    await fetch(WEBHOOK, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content: `🔥 SnapchatBot: ${message}`.slice(0, 1900) }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    console.error("Could not post to Discord webhook:", err.message);
  }
}

async function main() {
  ensureBlackFrame();

  const browser = await puppeteer.launch({
    headless: false, // headed under Xvfb on the server; looks like a normal browser
    userDataDir: USER_DATA_DIR,
    defaultViewport: { width: 1400, height: 900 },
    args: [
      "--window-size=1400,900",
      "--use-fake-ui-for-media-stream", // auto-allow camera permission
      "--use-fake-device-for-media-stream",
      `--use-file-for-fake-video-capture=${BLACK_Y4M}`,
      ...(process.getuid?.() === 0 ? ["--no-sandbox"] : []),
    ],
  });

  const page = (await browser.pages())[0] || (await browser.newPage());
  let exitCode = 0;
  const watchdog = setTimeout(() => {
    console.error("Run timed out, killing browser.");
    browser.process()?.kill("SIGKILL");
    process.exit(1);
  }, RUN_TIMEOUT);

  try {
    await sendSnap(page);
  } catch (err) {
    exitCode = err instanceof NotLoggedInError ? 2 : 1;
    console.error("FAILED:", err.message);
    try {
      fs.mkdirSync(LOG_DIR, { recursive: true });
      const shot = path.join(LOG_DIR, `failure-${new Date().toISOString().replace(/[:.]/g, "-")}.png`);
      await page.screenshot({ path: shot });
      console.error("Screenshot:", shot);
    } catch {}
    await notify(err.message);
  } finally {
    await sleep(2000);
    await browser.close().catch(() => {});
    clearTimeout(watchdog);
  }
  process.exit(exitCode);
}

main();

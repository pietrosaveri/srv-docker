// Automates sending a snap using the saved Chrome session from login.js
// (same userDataDir, so it must already be logged in — run `node login.js`
// first if not).
//
// Click sequence (as given):
//   1. button.qJKfS                     -> open camera / capture
//   2. div[role="button"][aria-roledescription="draggable"] -> confirm preview
//   3. button "Send To"
//   4. button "🔥" (streaks filter)
//   5. button "Select" (select all)
//   6. button[type="submit"] "Send"
//
// NOTE: Snapchat's web app uses auto-generated, obfuscated CSS class names
// (qJKfS, YatIx, etc.). These change whenever Snapchat ships a new build,
// so this script WILL break periodically and need its selectors re-captured
// from devtools. Text-based selectors (Send To, Select, Send) are more
// stable and used as a fallback where possible.

import puppeteer from "puppeteer";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const USER_DATA_DIR = path.join(__dirname, "chrome-profile");

const DEFAULT_TIMEOUT = 15000;

async function clickByClass(page, className, { timeout = DEFAULT_TIMEOUT } = {}) {
  const selector = `.${className.trim().split(/\s+/).join(".")}`;
  await page.waitForSelector(selector, { visible: true, timeout });
  await page.click(selector);
}

async function clickByText(page, tag, text, { timeout = DEFAULT_TIMEOUT } = {}) {
  const handle = await page.waitForFunction(
    (tag, text) => {
      const els = Array.from(document.querySelectorAll(tag));
      return els.find((el) => el.textContent.trim().includes(text)) || null;
    },
    { timeout },
    tag,
    text
  );
  const el = handle.asElement();
  if (!el) throw new Error(`Could not find <${tag}> containing "${text}"`);
  await el.click();
}

async function clickDraggable(page, { timeout = DEFAULT_TIMEOUT } = {}) {
  const selector = 'div[role="button"][aria-roledescription="draggable"]';
  await page.waitForSelector(selector, { visible: true, timeout });
  await page.click(selector);
}

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const browser = await puppeteer.launch({
    headless: false,
    userDataDir: USER_DATA_DIR,
    defaultViewport: null,
    args: ["--start-maximized"],
  });

  const [page] = await browser.pages();

  try {
    await page.goto("https://web.snapchat.com/", { waitUntil: "networkidle2" });

    if (page.url().includes("/login") || (await page.$('input[name="username"]'))) {
      throw new Error("Not logged in. Run `node login.js` first to create a session.");
    }

    console.log("1/6 Clicking capture button (.qJKfS)...");
    await clickByClass(page, "qJKfS");
    await sleep(1000);

    console.log("2/6 Clicking draggable preview confirm...");
    await clickDraggable(page);
    await sleep(1000);

    console.log('3/6 Clicking "Send To"...');
    try {
      await clickByClass(page, "YatIx fGS78 eKaL7 Bnaur");
    } catch {
      await clickByText(page, "button", "Send To");
    }
    await sleep(1000);

    console.log("4/6 Clicking streaks filter (🔥)...");
    try {
      await clickByClass(page, "c47Sk BmKCE");
    } catch {
      await clickByText(page, "button", "🔥");
    }
    await sleep(1000);

    console.log('5/6 Clicking "Select" (select all)...');
    try {
      await clickByClass(page, "Y7u8A");
    } catch {
      await clickByText(page, "button", "Select");
    }
    await sleep(1000);

    console.log('6/6 Clicking "Send"...');
    try {
      await clickByClass(page, "TYX6O eKaL7 Bnaur");
    } catch {
      await clickByText(page, "button", "Send");
    }

    console.log("Snap sent.");
  } catch (err) {
    console.error("Failed:", err.message);
  } finally {
    await sleep(2000);
    await browser.close();
  }
}

main();

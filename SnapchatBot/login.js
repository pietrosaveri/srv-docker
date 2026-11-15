// Opens Snapchat Web in the bot's Chrome profile so you can log in by hand,
// then saves the session for sendSnap.js.
//
// Usage:
//   npm install
//   node login.js
//
// Log in in the Chrome window (captcha / 2FA included). As soon as the chat
// feed appears the cookies are saved to cookies.json and the browser closes.
// Snapchat's auth cookies are session cookies that Chrome forgets on exit, so
// the profile directory alone is not enough; see session.js.
//
// On the server, run it under a display you can see (VNC into Xvfb, ssh -X),
// or log in on your laptop and copy chrome-profile/ and cookies.json over.

import puppeteer from "puppeteer";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { COOKIE_FILE, restoreCookies, saveCookies } from "./session.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const USER_DATA_DIR = path.join(__dirname, "chrome-profile");
const LOGIN_TIMEOUT = 10 * 60_000;

const FEED = '[aria-label="Friends feed"], button.qJKfS';

async function main() {
  const browser = await puppeteer.launch({
    headless: false,
    userDataDir: USER_DATA_DIR,
    defaultViewport: null,
    args: ["--window-size=1400,900"],
  });

  try {
    const page = (await browser.pages())[0] || (await browser.newPage());
    await restoreCookies(page);
    await page.goto("https://www.snapchat.com/web/", { waitUntil: "domcontentloaded" });

    const already = await page.waitForSelector(FEED, { timeout: 20_000 }).then(() => true, () => false);
    if (already) {
      console.log("Already logged in.");
    } else {
      console.log("Not logged in. Log in in the Chrome window (waiting up to 10 minutes)...");
      if (!page.url().includes("/web")) {
        // The logged-out redirect lands on the marketing page; its login form
        // works, but send the user to the real login page to be explicit.
        await page.goto("https://accounts.snapchat.com/v2/login?continue=https%3A%2F%2Fwww.snapchat.com%2Fweb%2F", {
          waitUntil: "domcontentloaded",
        });
      }
      await page.waitForSelector(FEED, { timeout: LOGIN_TIMEOUT });
      console.log("Logged in.");
    }

    await new Promise((r) => setTimeout(r, 5000)); // let late cookies land
    const n = await saveCookies(page);
    console.log(`Saved ${n} cookies to ${COOKIE_FILE}`);
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error("Login failed:", err.message);
  process.exit(1);
});

// Opens web.snapchat.com in a persistent Chrome profile so the session
// (cookies + localStorage) survives across runs. Log in once by hand here;
// any other script that launches Chrome with the same userDataDir will
// already be authenticated.
//
// Usage:
//   npm install
//   node login.js
//
// First run: a Chrome window opens on the Snapchat login page. Log in
// manually (solve any captcha/2FA yourself), wait for the app to load,
// then come back to the terminal and press Enter to close the browser
// and save the profile.

import puppeteer from "puppeteer";
import path from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline/promises";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const USER_DATA_DIR = path.join(__dirname, "chrome-profile");

async function waitForEnter(message) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  await rl.question(message);
  rl.close();
}

async function isLoggedIn(page) {
  // Snapchat web redirects to /login (or shows a login form) when unauthenticated.
  return !page.url().includes("/login") && !(await page.$('input[name="username"]'));
}

async function main() {
  const browser = await puppeteer.launch({
    headless: false,
    userDataDir: USER_DATA_DIR,
    defaultViewport: null,
    args: ["--start-maximized"],
  });

  const [page] = await browser.pages();
  await page.goto("https://web.snapchat.com/", { waitUntil: "networkidle2" });

  if (await isLoggedIn(page)) {
    console.log("Already logged in — session restored from saved Chrome profile.");
  } else {
    console.log("Not logged in yet.");
    console.log("Log in manually in the opened Chrome window.");
  }

  await waitForEnter("Press Enter here whenever you want to close the browser and save the session... ");
  await browser.close();
  console.log(`Session saved to ${USER_DATA_DIR}`);
  console.log("Reuse it by launching Chrome/Puppeteer with the same userDataDir — no login required.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

// Snapchat's auth cookies are *session* cookies: Chrome drops them when the
// browser closes, so a saved chrome-profile alone comes back logged out on
// the next launch. We keep our own cookie jar (cookies.json) and restore it
// into every new browser.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const COOKIE_FILE = path.join(__dirname, "cookies.json");

const isSnapchat = (domain) => /(^|\.)snapchat\.com$/.test(domain.replace(/^\./, ""));

export async function saveCookies(page) {
  const client = await page.createCDPSession();
  const { cookies } = await client.send("Network.getAllCookies");
  await client.detach();
  const snap = cookies.filter((c) => isSnapchat(c.domain));
  fs.writeFileSync(COOKIE_FILE, JSON.stringify(snap, null, 2), { mode: 0o600 });
  return snap.length;
}

export async function restoreCookies(page) {
  if (!fs.existsSync(COOKIE_FILE)) return 0;
  const saved = JSON.parse(fs.readFileSync(COOKIE_FILE, "utf8"));
  const now = Date.now() / 1000;
  const cookies = saved
    .filter((c) => c.session || c.expires === -1 || c.expires > now)
    .map(({ name, value, domain, path, secure, httpOnly, sameSite, expires, session, priority }) => ({
      name,
      value,
      domain,
      path,
      secure,
      httpOnly,
      ...(sameSite ? { sameSite } : {}),
      ...(priority ? { priority } : {}),
      ...(session || expires === -1 ? {} : { expires }),
    }));
  const client = await page.createCDPSession();
  await client.send("Network.setCookies", { cookies });
  await client.detach();
  return cookies.length;
}

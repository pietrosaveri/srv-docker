// Same send-snap flow as sendSnap.js, but instead of hardcoded CSS class
// selectors (which break every time Snapchat ships a new build), each step
// asks a local Ollama model to pick the right element from a snapshot of
// the page's currently visible clickable elements.
//
// Prerequisites:
//   - Ollama installed: https://ollama.com (this script starts/stops the
//     daemon itself if it isn't already running — see startOllama/stopOllama)
//   - Signed in for cloud models: ollama signin
//   - Model pulled: ollama pull gemma4:31b-cloud
//   - Session already saved: node login.js
//
// Usage:
//   node aiSendSnap.js
//   OLLAMA_MODEL=some-other-model node aiSendSnap.js   # override

import puppeteer from "puppeteer";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const USER_DATA_DIR = path.join(__dirname, "chrome-profile");

const OLLAMA_HOST = process.env.OLLAMA_HOST || "http://localhost:11434";
const OLLAMA_URL = `${OLLAMA_HOST}/api/generate`;
const OLLAMA_MODEL = process.env.OLLAMA_MODEL || "gemma4:31b-cloud";

// Your flow. Each step has a deterministic `match` (exact text / stable
// attributes) checked first — fast and never picks the wrong element. Only
// when that fails (e.g. Snapchat renamed an obfuscated class) do we fall
// back to asking the AI, passing it the same element snapshot.
const FLOW = [
  {
    goal: "Open the camera / start creating a new snap (the capture button)",
    match: (el) => el.className.split(/\s+/).includes("qJKfS"),
  },
  {
    goal: "Confirm the captured photo or video preview to proceed (a draggable preview element)",
    match: (el) => el.role === "button" && el.ariaRoleDescription === "draggable",
  },
  {
    goal: "Open the 'Send To' recipient screen",
    match: (el) => el.text.trim().toLowerCase() === "send to",
  },
  {
    goal: "Filter the recipient list to the streaks / fire emoji (🔥) tab",
    match: (el) => el.text.trim() === "🔥",
  },
  {
    goal: "Select all recipients currently shown in the list",
    match: (el) => el.text.trim().toLowerCase() === "select",
  },
  {
    goal: "Submit and send the snap (the final Send button)",
    match: (el) => el.type === "submit" && el.text.trim().toLowerCase().includes("send"),
  },
];

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function isOllamaRunning() {
  try {
    const res = await fetch(`${OLLAMA_HOST}/api/tags`, { signal: AbortSignal.timeout(2000) });
    return res.ok;
  } catch {
    return false;
  }
}

async function startOllama() {
  console.log("Starting Ollama daemon...");
  const child = spawn("ollama", ["serve"], { stdio: "ignore" });

  for (let i = 0; i < 30; i++) {
    if (await isOllamaRunning()) return child;
    await sleep(500);
  }

  child.kill();
  throw new Error("Ollama daemon did not become ready in time.");
}

async function getInteractiveElements(page) {
  return page.evaluate(() => {
    const nodes = Array.from(
      document.querySelectorAll('button, [role="button"], input[type="submit"]')
    ).filter((el) => {
      const rect = el.getBoundingClientRect();
      const style = window.getComputedStyle(el);
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.visibility !== "hidden" &&
        style.display !== "none"
      );
    });

    return nodes.map((el, i) => {
      el.setAttribute("data-ai-idx", String(i));
      return {
        index: i,
        tag: el.tagName.toLowerCase(),
        text: (el.textContent || "").trim().slice(0, 60),
        className: el.className || "",
        role: el.getAttribute("role") || "",
        ariaLabel: el.getAttribute("aria-label") || "",
        ariaRoleDescription: el.getAttribute("aria-roledescription") || "",
        type: el.getAttribute("type") || "",
      };
    });
  });
}

async function clickByIndex(page, index) {
  // Use a real synthetic mouse click (scroll into view + mousedown/mouseup
  // via CDP), not an in-page el.click() DOM call — Snapchat's capture
  // button distinguishes tap vs. hold-to-record based on actual pointer
  // timing, and a bare .click() call skips that, which was causing it to
  // register as a video instead of a photo.
  const handle = await page.evaluateHandle(
    (index) => document.querySelector(`[data-ai-idx="${index}"]`),
    index
  );
  const el = handle.asElement();
  if (!el) throw new Error(`Element with data-ai-idx=${index} not found`);
  await el.click();
  await handle.dispose();
}

async function askOllama(goal, elements) {
  const prompt = `You are controlling a web browser to complete one UI step in Snapchat's web app.

Goal for this step: "${goal}"

Below is a JSON array of the currently visible clickable elements on the page. Each has an "index".
${JSON.stringify(elements, null, 2)}

Pick the single element whose purpose best matches the goal. Reply with ONLY a JSON object like {"index": 3}. If none of the elements match the goal, reply {"index": -1}.`;

  const res = await fetch(OLLAMA_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model: OLLAMA_MODEL,
      prompt,
      stream: false,
      format: "json",
    }),
  });

  if (!res.ok) {
    throw new Error(`Ollama request failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  const parsed = parseModelJson(data.response);
  return typeof parsed.index === "number" ? parsed.index : -1;
}

function parseModelJson(raw) {
  // Some models ignore format:"json" and wrap the object in a markdown
  // code fence (```json ... ```) or add stray text around it.
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidate = fenced ? fenced[1] : raw;
  const objectMatch = candidate.match(/\{[\s\S]*\}/);
  const jsonText = objectMatch ? objectMatch[0] : candidate;
  return JSON.parse(jsonText.trim());
}

async function main() {
  let ollamaProcess = null;
  if (await isOllamaRunning()) {
    console.log("Ollama daemon already running — leaving it as is.");
  } else {
    ollamaProcess = await startOllama();
  }

  const stopOllama = () => {
    if (ollamaProcess) {
      console.log("Stopping Ollama daemon...");
      ollamaProcess.kill();
      ollamaProcess = null;
    }
  };
  process.on("SIGINT", () => {
    stopOllama();
    process.exit(1);
  });

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

    for (const [i, step] of FLOW.entries()) {
      await sleep(1200); // let the SPA render after the previous click
      const elements = await getInteractiveElements(page);

      let index = elements.findIndex(step.match);
      let via = "deterministic";
      if (index === -1) {
        via = "ai";
        index = await askOllama(step.goal, elements);
      }

      if (index < 0 || !elements[index]) {
        throw new Error(`Step ${i + 1}/${FLOW.length} failed — no matching element for: "${step.goal}"`);
      }

      const el = elements[index];
      console.log(
        `${i + 1}/${FLOW.length} [${via}] "${step.goal}" -> clicking [${el.tag}] "${el.text || el.ariaLabel || el.className}"`
      );
      await clickByIndex(page, index);
    }

    console.log("Snap sent.");
  } catch (err) {
    console.error("Failed:", err.message);
  } finally {
    await sleep(2000);
    await browser.close();
    stopOllama();
  }
}

main();

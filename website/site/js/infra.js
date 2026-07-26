// Infrastructure page: a list of diagram titles that open into a pannable,
// zoomable viewer. Mermaid is ~3.4 MB, so it is fetched only when the first
// diagram is opened, and each rendered SVG is cached after that.

(function () {
  "use strict";

  var DIAGRAMS = window.DIAGRAMS || [];
  var MIN_SCALE = 0.15;
  var MAX_SCALE = 8;

  var list = document.getElementById("diagram-list");
  var viewer = document.getElementById("viewer");
  var stage = document.getElementById("stage");
  var canvas = document.getElementById("canvas");
  var titleEl = document.getElementById("viewer-title");
  var noteEl = document.getElementById("viewer-note");
  var noteBody = document.getElementById("viewer-note-body");
  var statusEl = document.getElementById("viewer-status");
  var infoEl = document.getElementById("node-info");
  var zoomEl = document.getElementById("zoom-level");

  if (!list || !viewer || !stage || !canvas) return;

  var svgCache = {};
  var current = null;
  var lastFocus = null;

  /* ── mermaid loader ──────────────────────────────────── */

  var mermaidPromise = null;

  function loadMermaid() {
    if (mermaidPromise) return mermaidPromise;
    mermaidPromise = new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = "js/vendor/mermaid.min.js";
      s.onload = function () {
        window.mermaid.initialize({
          startOnLoad: false,
          theme: "base",
          fontFamily: "Inter, system-ui, sans-serif",
          fontSize: 14,
          flowchart: { htmlLabels: true, curve: "linear", padding: 14, nodeSpacing: 45, rankSpacing: 55 },
          sequence: { useMaxWidth: false, mirrorActors: false, boxMargin: 8 },
          // Ink surface, white nodes, primary red for accents, design.md's
          // palette with no second accent colour.
          themeVariables: {
            background: "#25282b",
            mainBkg: "#ffffff",
            nodeBorder: "#25282b",
            primaryColor: "#ffffff",
            primaryTextColor: "#25282b",
            primaryBorderColor: "#25282b",
            secondaryColor: "#f2f2f2",
            tertiaryColor: "#2f3336",
            lineColor: "#bebebe",
            textColor: "#ffffff",
            titleColor: "#ffffff",
            clusterBkg: "#2f3336",
            clusterBorder: "#7e7e7e",
            edgeLabelBackground: "#25282b",
            actorBkg: "#ffffff",
            actorBorder: "#25282b",
            actorTextColor: "#25282b",
            actorLineColor: "#7e7e7e",
            signalColor: "#bebebe",
            signalTextColor: "#ffffff",
            labelBoxBkgColor: "#ffffff",
            labelBoxBorderColor: "#25282b",
            labelTextColor: "#25282b",
            loopTextColor: "#bebebe",
            noteBkgColor: "#e60000",
            noteBorderColor: "#e60000",
            noteTextColor: "#ffffff",
            activationBkgColor: "#f2f2f2",
            activationBorderColor: "#e60000",
            sequenceNumberColor: "#ffffff"
          }
        });
        resolve(window.mermaid);
      };
      s.onerror = function () { reject(new Error("could not load mermaid")); };
      document.head.appendChild(s);
    });
    return mermaidPromise;
  }

  /* ── transform state ─────────────────────────────────── */

  var tx = 0, ty = 0, k = 1;

  function apply() {
    canvas.style.transform = "translate(" + tx + "px," + ty + "px) scale(" + k + ")";
    if (zoomEl) zoomEl.textContent = Math.round(k * 100) + "%";
  }

  function clampScale(v) {
    return Math.min(MAX_SCALE, Math.max(MIN_SCALE, v));
  }

  function zoomAt(px, py, factor) {
    var next = clampScale(k * factor);
    if (next === k) return;
    tx = px - (px - tx) * (next / k);
    ty = py - (py - ty) * (next / k);
    k = next;
    apply();
  }

  function fit() {
    var svg = canvas.querySelector("svg");
    if (!svg) return;
    var w = Number(svg.getAttribute("width")) || svg.clientWidth || 1;
    var h = Number(svg.getAttribute("height")) || svg.clientHeight || 1;
    var sw = stage.clientWidth, sh = stage.clientHeight;
    k = clampScale(Math.min(sw / w, sh / h) * 0.92);
    tx = (sw - w * k) / 2;
    ty = (sh - h * k) / 2;
    apply();
  }

  /* ── pointer interaction ─────────────────────────────── */

  var pointers = new Map();
  var dragging = false;
  var moved = false;
  var start = { x: 0, y: 0, tx: 0, ty: 0 };
  var pinch = null;

  function stagePoint(e) {
    var r = stage.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  stage.addEventListener("pointerdown", function (e) {
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 1) {
      dragging = true;
      moved = false;
      var p = stagePoint(e);
      start = { x: p.x, y: p.y, tx: tx, ty: ty };
      stage.setPointerCapture(e.pointerId);
      stage.classList.add("grabbing");
    } else if (pointers.size === 2) {
      dragging = false;
      var pts = Array.from(pointers.values());
      var r = stage.getBoundingClientRect();
      pinch = {
        dist: Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y),
        cx: (pts[0].x + pts[1].x) / 2 - r.left,
        cy: (pts[0].y + pts[1].y) / 2 - r.top
      };
    }
  });

  stage.addEventListener("pointermove", function (e) {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

    if (pinch && pointers.size === 2) {
      var pts = Array.from(pointers.values());
      var d = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      if (pinch.dist > 0) zoomAt(pinch.cx, pinch.cy, d / pinch.dist);
      pinch.dist = d;
      return;
    }

    if (!dragging) return;
    var p = stagePoint(e);
    var dx = p.x - start.x, dy = p.y - start.y;
    if (Math.abs(dx) > 3 || Math.abs(dy) > 3) moved = true;
    tx = start.tx + dx;
    ty = start.ty + dy;
    apply();
  });

  function endPointer(e) {
    pointers.delete(e.pointerId);
    if (pointers.size < 2) pinch = null;
    if (pointers.size === 0) {
      dragging = false;
      stage.classList.remove("grabbing");
    }
  }

  stage.addEventListener("pointerup", endPointer);
  stage.addEventListener("pointercancel", endPointer);

  // Zoom proportionally to the actual scroll delta, so a mouse notch and a
  // trackpad flick both feel gradual. deltaMode differs between browsers, so
  // normalise to pixels first, then cap how much any single event can do.
  stage.addEventListener("wheel", function (e) {
    e.preventDefault();
    var dy = e.deltaY;
    if (e.deltaMode === 1) dy *= 16;        // lines
    else if (e.deltaMode === 2) dy *= 400;  // pages
    var rate = e.ctrlKey ? 0.0022 : 0.0009; // ctrl+wheel is a pinch gesture
    var factor = Math.exp(-dy * rate);
    factor = Math.max(0.9, Math.min(1.11, factor));
    var p = stagePoint(e);
    zoomAt(p.x, p.y, factor);
  }, { passive: false });

  stage.addEventListener("dblclick", function (e) {
    var p = stagePoint(e);
    zoomAt(p.x, p.y, 1.35);
  });

  /* ── node info ───────────────────────────────────────── */

  function hideInfo() {
    if (!infoEl) return;
    infoEl.hidden = true;
    infoEl.textContent = "";
  }

  // x/y are stage-relative coordinates of the click that opened this.
  function showInfo(entry, x, y) {
    if (!infoEl) return;
    infoEl.textContent = "";
    var h = document.createElement("h4");
    h.textContent = entry.title;
    var p = document.createElement("p");
    p.textContent = entry.body;
    var close = document.createElement("button");
    close.type = "button";
    close.className = "info-close";
    close.setAttribute("aria-label", "Close details");
    close.textContent = "×";
    close.addEventListener("click", hideInfo);
    infoEl.appendChild(close);
    infoEl.appendChild(h);
    infoEl.appendChild(p);

    // Unhide before measuring, then keep the card fully inside the stage.
    infoEl.style.left = "0px";
    infoEl.style.top = "0px";
    infoEl.hidden = false;

    var w = infoEl.offsetWidth;
    var ht = infoEl.offsetHeight;
    var sw = stage.clientWidth;
    var sh = stage.clientHeight;
    var left = x + 16;
    var top = y + 16;
    if (left + w > sw - 8) left = x - w - 16;  // flip to the other side
    if (top + ht > sh - 8) top = y - ht - 16;
    infoEl.style.left = Math.max(8, Math.min(left, Math.max(8, sw - w - 8))) + "px";
    infoEl.style.top = Math.max(8, Math.min(top, Math.max(8, sh - ht - 8))) + "px";
  }

  // Mermaid ids look like "<renderId>-flowchart-Router-3"; recover the key.
  function nodeKey(g, renderId) {
    var id = g.id || "";
    var prefix = renderId + "-flowchart-";
    if (id.indexOf(prefix) === 0) {
      return id.slice(prefix.length).replace(/-\d+$/, "");
    }
    var m = /flowchart-(.+)-\d+$/.exec(id);
    return m ? m[1] : null;
  }

  function wireNodes(info, renderId) {
    var nodes = canvas.querySelectorAll("g.node");
    var hits = 0;
    nodes.forEach(function (g) {
      var key = nodeKey(g, renderId);
      var entry = key && info[key];
      if (!entry) return;
      hits++;
      g.classList.add("has-info");
      g.addEventListener("click", function (ev) {
        if (moved) return; // it was a pan, not a click
        ev.stopPropagation();
        var p = stagePoint(ev);
        showInfo(entry, p.x, p.y);
      });
    });
    return hits;
  }

  stage.addEventListener("click", function () {
    if (!moved) hideInfo();
  });

  /* ── open / close ────────────────────────────────────── */

  function setStatus(msg) {
    if (!statusEl) return;
    statusEl.textContent = msg || "";
    statusEl.hidden = !msg;
  }

  function prepareSvg() {
    var svg = canvas.querySelector("svg");
    if (!svg) return;
    svg.removeAttribute("style");
    svg.removeAttribute("width");
    svg.removeAttribute("height");
    var vb = svg.viewBox && svg.viewBox.baseVal;
    var w = vb && vb.width ? vb.width : 800;
    var h = vb && vb.height ? vb.height : 600;
    svg.setAttribute("width", String(w));
    svg.setAttribute("height", String(h));
    svg.style.display = "block";
  }

  function open(diagram, trigger) {
    current = diagram;
    lastFocus = trigger || document.activeElement;

    titleEl.textContent = diagram.title;
    if (noteBody) noteBody.textContent = diagram.note || "";
    noteEl.hidden = !diagram.note;
    noteEl.classList.remove("collapsed");
    var nt = document.getElementById("note-toggle");
    if (nt) {
      nt.textContent = "−";
      nt.setAttribute("aria-expanded", "true");
    }
    hideInfo();
    canvas.textContent = "";
    canvas.style.transform = "";
    viewer.hidden = false;
    document.body.classList.add("viewer-open");

    var closeBtn = document.getElementById("viewer-close");
    if (closeBtn) closeBtn.focus();

    if (svgCache[diagram.id]) {
      inject(svgCache[diagram.id], diagram);
      return;
    }

    setStatus("loading renderer…");
    loadMermaid()
      .then(function (mermaid) {
        setStatus("rendering…");
        return mermaid.render("mmd-" + diagram.id, diagram.src);
      })
      .then(function (res) {
        svgCache[diagram.id] = res.svg;
        if (current === diagram) inject(res.svg, diagram);
      })
      .catch(function (err) {
        setStatus("could not render this diagram, " + err.message);
      });
  }

  function inject(svgText, diagram) {
    canvas.innerHTML = svgText;
    prepareSvg();
    setStatus("");
    var hits = wireNodes(diagram.info || {}, "mmd-" + diagram.id);
    var hint = document.getElementById("viewer-hint");
    if (hint) {
      hint.textContent = hits
        ? "drag to pan · scroll to zoom · click a highlighted box for detail"
        : "drag to pan · scroll to zoom";
    }
    fit();
  }

  function close() {
    viewer.hidden = true;
    document.body.classList.remove("viewer-open");
    current = null;
    canvas.textContent = "";
    hideInfo();
    setStatus("");
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  /* ── controls ────────────────────────────────────────── */

  function ctl(id, fn) {
    var b = document.getElementById(id);
    if (b) b.addEventListener("click", fn);
  }

  ctl("viewer-close", close);
  ctl("note-toggle", function () {
    var collapsed = noteEl.classList.toggle("collapsed");
    var b = document.getElementById("note-toggle");
    b.textContent = collapsed ? "+" : "−";
    b.setAttribute("aria-expanded", String(!collapsed));
    b.setAttribute("aria-label", collapsed ? "Expand notes" : "Collapse notes");
  });
  ctl("zoom-in", function () { zoomAt(stage.clientWidth / 2, stage.clientHeight / 2, 1.25); });
  ctl("zoom-out", function () { zoomAt(stage.clientWidth / 2, stage.clientHeight / 2, 1 / 1.25); });
  ctl("zoom-fit", fit);

  // The overlay panels live inside the stage, so their pointer/wheel events
  // would otherwise pan the diagram, zoom it, or dismiss the popup.
  [noteEl, infoEl].forEach(function (panel) {
    if (!panel) return;
    ["pointerdown", "click", "dblclick"].forEach(function (type) {
      panel.addEventListener(type, function (e) { e.stopPropagation(); });
    });
    panel.addEventListener("wheel", function (e) { e.stopPropagation(); }, { passive: true });
  });

  document.addEventListener("keydown", function (e) {
    if (viewer.hidden) return;
    if (e.key === "Escape") { close(); return; }
    if (e.key === "+" || e.key === "=") { zoomAt(stage.clientWidth / 2, stage.clientHeight / 2, 1.25); }
    if (e.key === "-") { zoomAt(stage.clientWidth / 2, stage.clientHeight / 2, 1 / 1.25); }
    if (e.key === "0") fit();
  });

  window.addEventListener("resize", function () {
    if (!viewer.hidden && canvas.querySelector("svg")) fit();
  });

  /* ── build the list ──────────────────────────────────── */

  DIAGRAMS.forEach(function (d, i) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "diagram-row";

    var num = document.createElement("span");
    num.className = "d-num";
    num.textContent = String(i + 1).padStart(2, "0");

    var name = document.createElement("span");
    name.className = "d-title";
    name.textContent = d.title;

    var kind = document.createElement("span");
    kind.className = "d-kind";
    kind.textContent = d.kind;

    b.appendChild(num);
    b.appendChild(name);
    b.appendChild(kind);
    b.addEventListener("click", function () { open(d, b); });
    list.appendChild(b);
  });
})();

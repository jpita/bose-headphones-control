/* Bose Headphones Control — talks to the local server in server.py.
   Core idea: the firmware silently drops some writes, so every action
   re-reads the device and the UI reports stored values, never requested ones. */

"use strict";

const $ = (id) => document.getElementById(id);
let STATE = null;
let BUSY = false;

/* ── transport ──────────────────────────────────────────────────── */

async function getState() {
  const r = await fetch("/api/state");
  return r.json();
}

async function act(action, args) {
  const r = await fetch("/api/action", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action, args: args || {} }),
  });
  return r.json();
}

/* ── feedback ───────────────────────────────────────────────────── */

function toast(msg, kind) {
  const el = document.createElement("div");
  el.className = "toast" + (kind ? " " + kind : "");
  el.textContent = msg;
  $("toast").appendChild(el);
  setTimeout(() => el.remove(), kind === "bad" ? 6000 : 3400);
}

function logWrite(text, cls) {
  const box = $("writelog");
  const line = document.createElement("div");
  line.className = "log-line";
  const t = new Date().toLocaleTimeString();
  line.innerHTML = `<span class="ts">${t}</span> <span class="${cls || "rx"}">${escapeHtml(text)}</span>`;
  box.prepend(line);
}

/* The earcup button announces the mode; set_mode only does when asked.
   Kept per browser, since it is a preference rather than device state. */
function announceOn() {
  try {
    return localStorage.getItem("bmap.announce") === "1";
  } catch (e) {
    return false;
  }
}

function setAnnounce(on) {
  try {
    localStorage.setItem("bmap.announce", on ? "1" : "0");
  } catch (e) {
    /* private window or blocked storage: the toggle still works this session */
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

/* ── write + verify ─────────────────────────────────────────────── */

/* verify(state) returns null when the device stored what we asked,
   or a human sentence describing what it stored instead. */
async function run(label, action, args, verify) {
  if (BUSY) return null;
  BUSY = true;
  setEnabled(false);
  try {
    const res = await act(action, args);
    if (!res.ok) {
      toast(res.error, "bad");
      logWrite(`${label} — rejected: ${res.error}`, "er");
      return null;
    }
    if (res.state) STATE = res.state;
    const problem = verify ? verify(res.state) : null;
    if (problem) {
      toast(problem, "warn");
      logWrite(`${label} — ${problem}`, "er");
    } else {
      logWrite(`${label} — stored`, "rx");
    }
    return res;
  } catch (e) {
    toast("Server unreachable: " + e.message, "bad");
    return null;
  } finally {
    BUSY = false;
    setEnabled(true);
    // render last: it re-derives which controls are legitimately disabled.
    render();
  }
}

function setEnabled(on) {
  document.querySelectorAll("button, input, select").forEach((el) => {
    el.disabled = !on;
  });
}

/* ── render ─────────────────────────────────────────────────────── */

function render() {
  if (!STATE) return;
  const st = STATE.status;
  const dev = STATE.device || {};

  $("dev-name").textContent = st.name || dev.name || "Headphones";
  $("dev-sub").textContent =
    [dev.name, st.firmware ? `fw ${st.firmware}` : null]
      .filter(Boolean).join("  ·  ");

  const pct = Number(st.battery) || 0;
  $("batt-fill").style.width = pct + "%";
  $("batt-fill").classList.toggle("low", pct <= 20);
  $("batt-pct").textContent = pct + "%";
  $("rail-mode").textContent = st.mode || "--";
  $("link-dot").className = "dot on";
  $("link-txt").textContent = "connected";

  renderModes();
  renderNoise();
  renderEq();
  renderSlots();
  renderSettings();
  renderButtons();
}

function currentProfile() {
  return (STATE.profiles || []).find((p) => p.mode_idx === STATE.status.mode_idx);
}

function renderModes() {
  const box = $("mode-buttons");
  box.innerHTML = "";
  (STATE.profiles || []).forEach((p) => {
    // An empty custom slot is not something you can listen to. Firmware never
    // clears the 'configured' bit once a slot has been written, so a blank
    // name is the only reliable test for empty.
    if (p.editable && !(p.name || "").trim()) return;
    const b = document.createElement("button");
    b.textContent = p.name;
    b.className = p.mode_idx === STATE.status.mode_idx ? "active" : "";
    b.onclick = () => run(`Switch to ${p.name}`, "set_mode",
      { name: p.name, announce: announceOn() },
      (s) => s.status.mode_idx === p.mode_idx ? null
        : `Device stayed on "${s.status.mode}".`);
    box.appendChild(b);
  });
}

function renderNoise() {
  const prof = currentProfile();
  const st = STATE.status;
  const section = $("noise-section");
  const note = $("cnc-note");
  const controls = $("noise-controls");

  // A preset slot takes no writes, so there is no Noise Control UI to show.
  const locked = !prof || !prof.editable;
  section.hidden = locked;

  if (locked) {
    return;
  }

  section.hidden = false;
  controls.hidden = false;

  $("cnc").max = st.cnc_max || 10;
  $("cnc").value = st.cnc_level;
  $("cnc-val").textContent = st.cnc_level;
  $("wind").checked = !!prof.wind_block;
  $("anc").checked = !!prof.anc_toggle;

  if (prof.wind_block) {
    note.className = "note bad";
    note.innerHTML = `<span><strong>Wind block is on.</strong> This firmware zeroes the
      noise level whenever wind block is set in the same write, so the level below
      will not stick. Turn wind block off to set a level.</span>`;
  } else {
    note.className = "note";
    note.innerHTML = `<span>Scale is inverted: <code>0</code> is full noise cancelling,
      <code>${st.cnc_max}</code> is maximum ambient sound.</span>`;
  }
}

/* Controls the firmware accepted but did not act on. Some settings are
   read-only in practice and report no error, so the only way to know is to
   write once and look. Remembered for the session so the note persists. */
const REFUSED = new Map();

const BAND_LABEL = { 1: "Bass", 2: "Mid", 3: "Treble" };

function renderEq() {
  const bands = STATE.status.eq || [];
  const box = $("eq-sliders");
  box.innerHTML = "";

  bands.forEach((b, i) => {
    const row = document.createElement("div");
    row.className = "slider-row";
    const name = b.name || BAND_LABEL[b.band_id] || `Band ${b.band_id}`;
    row.innerHTML = `
      <span class="lab">${escapeHtml(name)}</span>
      <input type="range" min="${b.min_val}" max="${b.max_val}" step="1"
             value="${b.current}" data-band="${i}">
      <span class="val">${b.current > 0 ? "+" : ""}${b.current}</span>`;
    const slider = row.querySelector("input");
    slider.oninput = () => {
      row.querySelector(".val").textContent =
        (slider.value > 0 ? "+" : "") + slider.value;
      drawEqCurve(readEqSliders());
    };
    slider.onchange = () => applyEq(readEqSliders());
    box.appendChild(row);
  });

  drawEqCurve(bands.map((b) => b.current));
}

function readEqSliders() {
  return [...document.querySelectorAll("#eq-sliders input[type=range]")]
    .map((s) => Number(s.value));
}

function applyEq(vals) {
  const [bass, mid, treble] = vals;
  return run(`EQ ${bass}/${mid}/${treble}`, "set_eq", { bass, mid, treble },
    (s) => {
      const got = (s.status.eq || []).map((b) => b.current);
      return got.join(",") === vals.join(",") ? null
        : `Device stored EQ ${got.join("/")} instead of ${vals.join("/")}.`;
    });
}

/* Response curve: three control points, smoothed, drawn to the band range. */
function drawEqCurve(vals) {
  const svg = $("eq-svg");
  // Bottom padding keeps the band labels clear of the lowest gridline label.
  const W = 600, H = 104, pad = 10, padB = 22;
  const bands = STATE.status.eq || [];
  const lo = bands.length ? bands[0].min_val : -10;
  const hi = bands.length ? bands[0].max_val : 10;
  if (!vals.length) { svg.innerHTML = ""; return; }

  const y = (v) => pad + (hi - v) / (hi - lo) * (H - pad - padB);
  const step = (W - pad * 2) / (vals.length - 1 || 1);
  const pts = vals.map((v, i) => [pad + i * step, y(v)]);

  let d = `M ${pts[0][0]} ${pts[0][1]}`;
  for (let i = 1; i < pts.length; i++) {
    const [x0, y0] = pts[i - 1], [x1, y1] = pts[i];
    const mx = (x0 + x1) / 2;
    d += ` C ${mx} ${y0} ${mx} ${y1} ${x1} ${y1}`;
  }
  const area = `${d} L ${pts[pts.length - 1][0]} ${y(0)} L ${pts[0][0]} ${y(0)} Z`;

  const ticks = [hi, 0, lo].map((v) =>
    `<line x1="${pad}" y1="${y(v)}" x2="${W - pad}" y2="${y(v)}"
       stroke="currentColor" stroke-width="1" opacity="${v === 0 ? .45 : .18}"
       ${v === 0 ? "" : 'stroke-dasharray="3 4"'} />
     <text x="${pad + 2}" y="${y(v) - 3}" font-size="9" fill="currentColor"
       opacity=".55" font-family="IBM Plex Mono, monospace">${v > 0 ? "+" : ""}${v}</text>`
  ).join("");

  const labels = vals.map((v, i) => {
    const name = bands[i] ? (bands[i].name || BAND_LABEL[bands[i].band_id]) : "";
    return `<text x="${pts[i][0]}" y="${H - 1}" font-size="9" fill="currentColor"
      opacity=".6" text-anchor="${i === 0 ? "start" : i === vals.length - 1 ? "end" : "middle"}"
      font-family="IBM Plex Sans Condensed, sans-serif">${escapeHtml(name)}</text>`;
  }).join("");

  svg.style.color = getComputedStyle(document.body).getPropertyValue("--muted");
  svg.innerHTML = `
    ${ticks}
    <path d="${area}" fill="var(--accent)" opacity=".13" />
    <path d="${d}" fill="none" stroke="var(--accent)" stroke-width="2"
          stroke-linecap="round" stroke-linejoin="round" />
    ${pts.map(([x, yy]) => `<circle cx="${x}" cy="${yy}" r="3"
        fill="var(--accent)" />`).join("")}
    ${labels}`;
}

function renderSlots() {
  const box = $("slots");
  box.innerHTML = "";
  const editable = STATE.editable_slots || [];
  $("slot-hint").textContent = editable.length
    ? `Slots ${editable.join(" and ")} are writable on this device.`
    : "";

  (STATE.profiles || []).forEach((p) => {
    const el = document.createElement("div");
    el.className = "slot" + (p.editable ? "" : " preset") +
      (p.mode_idx === STATE.status.mode_idx ? " current" : "");

    const named = p.name && p.name.trim();
    const meta = [`cnc=${p.cnc_level}`,
      p.wind_block ? "wind=on" : "wind=off",
      p.spatial ? `spatial=${p.spatial}` : null].filter(Boolean).join("  ");

    el.innerHTML = `
      <span class="idx">${p.mode_idx}</span>
      <span>
        <span class="nm ${named ? "" : "empty"}">${escapeHtml(named || "empty slot")}</span>
        ${p.mode_idx === STATE.status.mode_idx ? '<span class="tag live">active</span>' : ""}
        ${p.editable ? "" : '<span class="tag">preset</span>'}
        <div class="meta">${meta}</div>
      </span>
      <span class="ctl"></span>`;

    const ctl = el.querySelector(".ctl");

    if (p.editable) {
      const nameIn = document.createElement("input");
      nameIn.type = "text";
      nameIn.value = named || "";
      nameIn.placeholder = "name";
      nameIn.size = 10;
      nameIn.style.width = "110px";

      const cncIn = document.createElement("input");
      cncIn.type = "number";
      cncIn.min = 0; cncIn.max = STATE.status.cnc_max || 10;
      cncIn.value = p.cnc_level;
      cncIn.style.width = "62px";
      cncIn.title = "CNC level";

      const windLab = document.createElement("label");
      windLab.className = "sw";
      windLab.title = "Wind block";
      windLab.innerHTML = `<input type="checkbox" ${p.wind_block ? "checked" : ""}>
        <span class="track"></span><span style="font-size:12.5px">wind</span>`;

      const save = document.createElement("button");
      save.textContent = named ? "Save" : "Create";
      save.onclick = () => {
        const nm = nameIn.value.trim();
        if (!nm) { toast("Give the profile a name first.", "bad"); return; }
        const wind = windLab.querySelector("input").checked;
        const cnc = Number(cncIn.value);
        run(`Slot ${p.mode_idx}: ${nm} cnc=${cnc} wind=${wind ? "on" : "off"}`,
          "set_profile",
          { slot: p.mode_idx, name: nm, cnc_level: cnc, wind_block: wind },
          (s) => {
            const now = (s.profiles || []).find((x) => x.mode_idx === p.mode_idx);
            if (!now) return "Slot disappeared after the write.";
            if (now.cnc_level !== cnc) {
              return wind
                ? `Device stored cnc=${now.cnc_level}. Wind block blocks the CNC level on this firmware.`
                : `Device stored cnc=${now.cnc_level} instead of ${cnc}.`;
            }
            return null;
          });
      };

      const del = document.createElement("button");
      del.textContent = "Clear";
      del.className = "danger";
      del.disabled = !named;
      del.onclick = () => run(`Clear slot ${p.mode_idx}`, "delete_profile",
        { slot: p.mode_idx }, null);

      ctl.append(nameIn, cncIn, windLab, save, del);
    }

    if (named && p.mode_idx !== STATE.status.mode_idx) {
      const go = document.createElement("button");
      go.textContent = "Activate";
      go.onclick = () => run(`Switch to ${named}`, "set_mode",
        { name: named, announce: announceOn() }, null);
      ctl.appendChild(go);
    }

    box.appendChild(el);
  });
}

function renderSettings() {
  const st = STATE.status;
  const box = $("settings");
  const feats = STATE.features || [];
  box.innerHTML = "";

  // Device name
  const nameWrap = document.createElement("label");
  nameWrap.className = "field";
  nameWrap.innerHTML = `<span class="lab">Device name</span>`;
  const nameRow = document.createElement("span");
  nameRow.className = "row";
  const nameIn = document.createElement("input");
  nameIn.type = "text";
  nameIn.value = st.name || "";
  nameIn.style.flex = "1";
  const nameBtn = document.createElement("button");
  nameBtn.textContent = "Rename";
  nameBtn.onclick = () => run(`Rename to "${nameIn.value}"`, "set_name",
    { new_name: nameIn.value },
    (s) => s.status.name === nameIn.value ? null
      : `Device kept the name "${s.status.name}".`);
  nameRow.append(nameIn, nameBtn);
  nameWrap.appendChild(nameRow);
  box.appendChild(nameWrap);

  // Sidetone
  if (feats.includes("sidetone")) {
  const sideWrap = document.createElement("label");
  sideWrap.className = "field";
  sideWrap.innerHTML = `<span class="lab">Sidetone (your voice in calls)</span>`;
  const sel = document.createElement("select");
  ["off", "low", "medium", "high"].forEach((v) => {
    const o = document.createElement("option");
    o.value = v; o.textContent = v;
    o.selected = String(st.sidetone) === v;
    sel.appendChild(o);
  });
  sel.onchange = () => run(`Sidetone ${sel.value}`, "set_sidetone",
    { level: sel.value },
    (s) => String(s.status.sidetone) === sel.value ? null
      : `Device stored sidetone "${s.status.sidetone}".`);
  sideWrap.appendChild(sel);
  box.appendChild(sideWrap);
  }

  // Only settings this device honours. auto_pause and auto_answer are absent
  // from the QC45 feature table, and multipoint reads but ignores every write,
  // so neither belongs on screen as something you can change.
  const toggles = [];
  if (feats.includes("voice_prompts")) {
    toggles.push(["prompts",
      "Voice prompts" + (st.prompts_language ? ` (${st.prompts_language})` : ""),
      "set_prompts", st.prompts_enabled]);
  }
  if (feats.includes("auto_pause")) {
    toggles.push(["auto_pause", "Pause when removed", "set_auto_pause", st.auto_pause]);
  }
  if (feats.includes("auto_answer")) {
    toggles.push(["auto_answer", "Auto-answer calls", "set_auto_answer", st.auto_answer]);
  }

  if (toggles.length) {
    const tBox = document.createElement("div");
    tBox.className = "field";
    tBox.innerHTML = `<span class="lab">Behaviour</span>`;
    const tRows = document.createElement("div");
    tRows.className = "grid";
    tRows.style.gap = "10px";

    toggles.forEach(([key, label, action, value]) => {
      const lab = document.createElement("label");
      lab.className = "sw";
      lab.innerHTML = `<input type="checkbox" ${value ? "checked" : ""}>
        <span class="track"></span><span>${escapeHtml(label)}</span>`;
      const input = lab.querySelector("input");
      input.onchange = () => run(`${label}: ${input.checked ? "on" : "off"}`,
        action, { enabled: input.checked },
        (s2) => {
          const now = key === "prompts" ? s2.status.prompts_enabled : s2.status[key];
          if (!!now === input.checked) { REFUSED.delete(key); return null; }
          REFUSED.set(key, `This firmware keeps it ${now ? "on" : "off"}.`);
          return `Device kept it ${now ? "on" : "off"}.`;
        });

      tRows.appendChild(lab);
      if (REFUSED.has(key)) {
        const why = document.createElement("div");
        why.className = "dim";
        why.style.cssText = "font-size:12px; margin:-4px 0 0 48px";
        why.textContent = REFUSED.get(key);
        tRows.appendChild(why);
      }
    });

    tBox.appendChild(tRows);
    box.appendChild(tBox);
  }
}

function renderButtons() {
  const box = $("buttons-box");
  const data = STATE.buttons;
  if (!data || !data.length) {
    box.innerHTML = `<p class="dim">${escapeHtml(
      STATE.buttons_error || "This device reports no remappable buttons.")}</p>`;
    return;
  }

  // Shown, not editable. The action a button currently has is often missing
  // from the device's own supported list, so a change could not be undone.
  const rows = data.map((b) => `<tr>
      <td>${escapeHtml(b.button_name || String(b.button_id))}</td>
      <td class="mono">${escapeHtml(b.event_name || String(b.event))}</td>
      <td class="mono">${escapeHtml(b.action_name || String(b.action))}</td>
    </tr>`).join("");

  box.innerHTML = `<table>
    <thead><tr><th>Button</th><th>Event</th><th>Does</th></tr></thead>
    <tbody>${rows}</tbody></table>`;
}

/* ── wiring ─────────────────────────────────────────────────────── */

$("cnc").oninput = () => { $("cnc-val").textContent = $("cnc").value; };
$("cnc").onchange = () => {
  const want = Number($("cnc").value);
  run(`CNC ${want}`, "set_cnc", { level: want }, (s) =>
    s.status.cnc_level === want ? null
      : `Device stored cnc=${s.status.cnc_level}. ` +
        (currentProfile() && currentProfile().wind_block
          ? "Wind block blocks the CNC level on this firmware."
          : "The active mode may be read-only."));
};

$("anc").onchange = () => run(`ANC ${$("anc").checked ? "on" : "off"}`,
  "set_anc", { enabled: $("anc").checked }, null);

$("wind").onchange = () => run(`Wind block ${$("wind").checked ? "on" : "off"}`,
  "set_wind", { enabled: $("wind").checked }, (s) => {
    const p = (s.profiles || []).find((x) => x.mode_idx === s.status.mode_idx);
    if (!p) return null;
    return !!p.wind_block === $("wind").checked ? null
      : `Device kept wind block ${p.wind_block ? "on" : "off"}.`;
  });

document.querySelectorAll("button[data-eq]").forEach((b) => {
  b.onclick = () => applyEq(b.dataset.eq.split(",").map(Number));
});

$("announce").checked = announceOn();
$("announce").onchange = () => {
  setAnnounce($("announce").checked);
  toast($("announce").checked
    ? "Mode changes will be announced out loud."
    : "Mode changes will be silent.");
};

$("refresh").onclick = () => load();

$("reconnect").onclick = async () => {
  const btn = $("reconnect");
  btn.disabled = true;
  btn.textContent = "Reconnecting…";
  try {
    const res = await act("reconnect", {});
    if (!res.ok) { toast(res.error, "bad"); return; }
    STATE = res.state;
    $("fatal").classList.add("hide");
    render();
    toast("Reconnected.");
  } catch (e) {
    toast("Server unreachable: " + e.message, "bad");
  } finally {
    btn.disabled = false;
    btn.textContent = "Reconnect";
  }
};

$("raw-send").onclick = async () => {
  const hex = $("raw-hex").value.trim();
  if (!hex) return;
  rawLog("TX  " + hex, "tx");
  const res = await act("send_raw", { hex_str: hex });
  if (!res.ok) { rawLog("ERR " + res.error, "er"); return; }
  const list = res.result || [];
  if (!list.length) rawLog("RX  (no response)", "rx");
  list.forEach((r) => rawLog(
    `RX  [${r.fblock}.${r.func}] op=${r.op} ${r.payload || "(empty)"}`, "rx"));
  if (res.state) { STATE = res.state; render(); }
};

$("raw-clear").onclick = () => { $("rawlog").innerHTML = ""; };

function rawLog(text, cls) {
  const line = document.createElement("div");
  line.className = "log-line";
  line.innerHTML = `<span class="${cls}">${escapeHtml(text)}</span>`;
  $("rawlog").prepend(line);
}

$("act-pair").onclick = () => {
  if (!confirm("Put the headphones into Bluetooth pairing mode?")) return;
  run("Pairing mode", "pair", {}, null);
};

$("act-off").onclick = () => {
  if (!confirm("Power off the headphones? You will lose this connection.")) return;
  run("Power off", "power_off", {}, null);
};

/* ── boot ───────────────────────────────────────────────────────── */

async function load() {
  $("link-dot").className = "dot";
  $("link-txt").textContent = "reading…";
  try {
    const res = await getState();
    if (!res.ok) throw new Error(res.error);
    STATE = res.state;
    $("fatal").classList.add("hide");
    render();
  } catch (e) {
    $("link-dot").className = "dot err";
    $("link-txt").textContent = "no device";
    $("fatal").classList.remove("hide");
    $("fatal").innerHTML = `<span><strong>Cannot reach the headphones.</strong>
      ${escapeHtml(e.message)}<br>Power them on, connect them to this machine,
      then press Refresh.</span>`;
  }
}

load();

/* ── background poll ────────────────────────────────────────────── */

/* A full read costs about 3 seconds of Bluetooth round trips, so the timer
   asks for two cheap values and only pulls the full state when one moved.
   This is what catches changes made on the headphones themselves. */
const POLL_MS = 6000;
let pollTimer = null;

async function poll() {
  if (BUSY || document.hidden || !STATE) return;
  try {
    const res = await fetch("/api/poll");
    const data = await res.json();
    if (!data.ok) {
      if (data.stale) await load();
      return;
    }
    const changed =
      data.poll.mode_idx !== STATE.status.mode_idx ||
      data.poll.battery !== STATE.status.battery;
    if (changed) await load();
  } catch (e) {
    /* server restarting or asleep: the next tick tries again */
  }
}

// Polling while hidden spends Bluetooth round trips nobody is looking at.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) poll();
});

pollTimer = setInterval(poll, POLL_MS);

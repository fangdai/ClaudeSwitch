"use strict";
(() => {
  // ---- session token (passed in the URL fragment, never sent to other sites) ----------
  const hashToken = new URLSearchParams(location.hash.slice(1)).get("t");
  if (hashToken) {
    try { sessionStorage.setItem("cs-token", hashToken); } catch (_) {}
    history.replaceState(null, "", location.pathname);
  }
  let token = hashToken;
  try { token = token || sessionStorage.getItem("cs-token"); } catch (_) {}

  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  };

  const S = {
    status: null, job: null, usageBusy: false, noticeId: null,
    tab: localGet("cs-tab") || "desktop", dismissedJob: 0, editing: null,
    lastUsage: 0, busyAction: false,
  };

  function localGet(k) { try { return localStorage.getItem(k); } catch (_) { return null; } }
  function localSet(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }

  async function api(path, body) {
    const res = await fetch(path, {
      method: body ? "POST" : "GET",
      headers: Object.assign({ "X-CS-Token": token || "" }, body ? { "Content-Type": "application/json" } : {}),
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || "Không kết nối được Claude Switch.");
    return data;
  }

  async function act(action, extra) {
    if (S.busyAction) return;
    S.busyAction = true;
    render();
    try {
      const r = await api("/api/action", Object.assign({ action }, extra || {}));
      if (r.message) toast(r.message);
      return r;
    } catch (e) {
      toast(e.message, true);
    } finally {
      S.busyAction = false;
      await refresh();
    }
  }

  // ---- toast ---------------------------------------------------------------------------
  let toastTimer;
  function toast(msg, isError) {
    const t = $("toast");
    t.textContent = msg;
    t.classList.toggle("error", !!isError);
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (t.hidden = true), isError ? 9000 : 6000);
  }

  // ---- polling ---------------------------------------------------------------------------
  let pollTimer;
  async function refresh() {
    try {
      const r = await api("/api/status");
      S.status = r.status;
      S.job = r.job;
      S.usageBusy = r.usageBusy;
      if (S.noticeId !== null && r.noticeId !== S.noticeId && r.notice) toast(r.notice);
      S.noticeId = r.noticeId;
    } catch (e) {
      $("info").hidden = false;
      $("info").textContent = "Mất kết nối với Claude Switch. Hãy mở lại ứng dụng.";
      return;
    }
    render();
  }
  function schedule() {
    clearTimeout(pollTimer);
    const running = S.job && !S.job.done;
    const delay = running ? 700 : document.hidden ? 20000 : 2500;
    pollTimer = setTimeout(async () => { await refresh(); maybeUsage(); schedule(); }, delay);
  }
  function maybeUsage(force) {
    if (document.hidden && !force) return;
    if (!force && Date.now() - S.lastUsage < 180000) return;
    S.lastUsage = Date.now();
    api("/api/action", { action: "usage.refresh", force: !!force }).catch(() => {});
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { refresh(); maybeUsage(); schedule(); } });

  // ---- rendering ---------------------------------------------------------------------------
  const STEP_LABELS = {
    close: "Đóng Claude", backup: "Sao lưu", sync: "Đồng bộ session",
    switch: "Đổi tài khoản", open: "Mở lại Claude", login: "Đăng nhập account mới", done: "Hoàn tất",
  };
  const JOB_STEPS = {
    switch: ["close", "backup", "sync", "switch", "open"],
    cancelAdd: ["close", "backup", "sync", "switch", "open"],
    add: ["close", "backup", "switch", "open", "login"],
    sync: [],
  };
  const JOB_TITLES = {
    switch: ["Đang chuyển tài khoản", "Đã chuyển tài khoản", "Chưa chuyển được tài khoản"],
    cancelAdd: ["Đang quay lại account cũ", "Đã quay lại account cũ", "Chưa quay lại được"],
    add: ["Đang chuẩn bị thêm account", "Hãy đăng nhập account còn lại", "Chưa thêm được account"],
    sync: ["Đang đồng bộ session", "Đã đồng bộ session", "Chưa đồng bộ được session"],
  };

  let lastSig = "";
  function render() {
    const st = S.status;
    if (!st) return;
    // Polling returns the same data most of the time: keep the DOM (focus, hover) as is.
    const sig = JSON.stringify([st, S.job, S.usageBusy, S.busyAction, S.tab, S.dismissedJob]);
    if (sig === lastSig) return;
    lastSig = sig;
    renderTabs(st);
    const job = S.job;
    const pending = st.desktop.pendingAdd;
    const showJob = job && job.id !== S.dismissedJob && (!job.done || job.kind !== "add" || !job.ok || pending);
    if (showJob) return renderProgress(job, pending);
    if (pending && S.tab === "desktop") return renderWaitLogin();
    $("progress").hidden = true;
    $("main").hidden = false;
    $("syncChk").checked = !!st.settings.syncSessions;
    $("confirmChk").checked = !st.settings.skipConfirm;
    if (S.tab === "cli") renderCli(st); else renderDesktop(st);
    const u = $("usageBtn");
    u.disabled = S.usageBusy;
    u.textContent = S.usageBusy ? "Đang cập nhật…" : "Cập nhật usage";
  }

  function renderTabs(st) {
    const tabs = $("tabs");
    const avail = [];
    if (st.desktop.installed) avail.push(["desktop", "Desktop"]);
    if (st.cli.installed) avail.push(["cli", "CLI"]);
    if (!avail.some(([k]) => k === S.tab) && avail.length) S.tab = avail[0][0];
    tabs.replaceChildren();
    if (avail.length < 2) return;
    for (const [k, label] of avail) {
      const b = el("button", "tab", label);
      b.setAttribute("role", "tab");
      b.setAttribute("aria-selected", String(k === S.tab));
      b.onclick = () => { S.tab = k; localSet("cs-tab", k); render(); };
      tabs.append(b);
    }
  }

  function info(text, warn) {
    const i = $("info");
    i.hidden = !text;
    i.textContent = text || "";
    i.classList.toggle("warn", !!warn);
  }

  function usageFor(uuid) {
    const acc = S.status.usage && S.status.usage.accounts;
    return acc ? acc[uuid.toLowerCase()] : null;
  }

  function fmtTime(iso) {
    const d = new Date(iso);
    if (isNaN(d)) return "";
    const p = (n) => String(n).padStart(2, "0");
    return `${p(d.getHours())}:${p(d.getMinutes())} · ${p(d.getDate())}/${p(d.getMonth() + 1)}`;
  }

  function renderUsage(box, uuid) {
    const r = usageFor(uuid);
    if (!r) { box.append(el("div", "usage-note", "Usage chưa được cập nhật.")); return; }
    for (const w of r.windows || []) {
      const row = el("div", "uw-row");
      row.append(el("span", "", w.label), el("span", "", `Đã dùng ${Math.round(w.usedPercent * 10) / 10}%`));
      const bar = el("div", "bar" + (w.usedPercent >= 90 ? " hot" : ""));
      const fill = el("i");
      fill.style.width = Math.max(0, Math.min(100, w.usedPercent)) + "%";
      bar.append(fill);
      box.append(row, bar);
      if (w.resetsAt) box.append(el("div", "uw-reset", "Reset " + fmtTime(w.resetsAt)));
    }
    if (r.updatedAt) box.append(el("div", "usage-note", (r.state === "ok" ? "Cập nhật " : "Dữ liệu lưu lúc ") + fmtTime(r.updatedAt)));
    if (r.message) box.append(el("div", "usage-note", r.message));
  }

  function card(p, opts) {
    const n = $("cardTpl").content.firstElementChild.cloneNode(true);
    const label = p.label || opts.fallback;
    n.querySelector(".avatar").textContent = (label || "?").trim().charAt(0).toUpperCase();
    n.querySelector(".name").textContent = label;
    n.querySelector(".email").textContent = p.email || "";
    n.querySelector(".meta").textContent = opts.meta || "";
    if (!opts.meta) n.querySelector(".meta").hidden = true;
    if (p.isActive) { n.classList.add("active"); n.querySelector(".badge").hidden = false; }
    const edit = n.querySelector(".edit");
    edit.onclick = () => startEdit(n, p, opts.labelAction);
    renderUsage(n.querySelector(".usage"), p.uuid);
    if (opts.switchText) {
      const b = n.querySelector(".switch");
      b.hidden = false;
      b.textContent = opts.switchText;
      b.disabled = !!opts.disabled || S.busyAction;
      b.onclick = opts.onSwitch;
    }
    return n;
  }

  function startEdit(cardEl, p, action) {
    const nameEl = cardEl.querySelector(".name");
    const input = el("input", "name-input");
    input.value = p.label || "";
    input.maxLength = 30;
    nameEl.replaceWith(input);
    S.editing = p.uuid;
    input.focus();
    input.select();
    let done = false;
    const finish = async (save) => {
      if (done) return;
      done = true;
      S.editing = null;
      lastSig = "";
      if (save && input.value.trim() && input.value.trim() !== p.label) await act(action, { uuid: p.uuid, label: input.value.trim() });
      else render();
    };
    input.onkeydown = (ev) => { if (ev.key === "Enter") finish(true); if (ev.key === "Escape") finish(false); };
    input.onblur = () => finish(true);
  }

  function setCards(nodes) {
    if (S.editing) return; // do not interrupt typing
    $("cards").replaceChildren(...nodes);
  }

  function emptyBox(title, text) {
    const b = el("div", "empty");
    b.append(el("h3", "", title), el("p", "muted", text));
    return b;
  }

  function btn(text, cls, onClick, disabled) {
    const b = el("button", "btn " + (cls || ""), text);
    b.onclick = onClick;
    b.disabled = !!disabled || S.busyAction;
    return b;
  }

  function renderDesktop(st) {
    const d = st.desktop;
    if (!d.installed) {
      info("");
      setCards([emptyBox("Chưa thấy Claude Desktop", st.platform === "linux"
        ? "Claude Desktop chưa có bản chính thức cho Linux. Bạn vẫn dùng được mục CLI."
        : "Cài và đăng nhập Claude Desktop, rồi mở lại Claude Switch.")]);
      $("actions").replaceChildren();
      return;
    }
    if (d.configError) info(d.configError, true);
    else if (d.recentActive > 0) info(`Có ${d.recentActive} session Claude Code vừa hoạt động. Chuyển account sẽ đóng Claude và dừng chúng.`, true);
    else if (!d.loggedIn && !d.profiles.length) info("Mở Claude và đăng nhập account đầu tiên. Claude Switch sẽ tự lưu lại.");
    else if (d.profiles.length < 2) info("Bấm “Thêm account” để lưu account thứ hai. Đăng xuất trên máy chủ không xảy ra, đăng nhập đã lưu vẫn còn.");
    else info("");
    const nodes = d.profiles.map((p) => card(p, {
      fallback: "Account",
      meta: `${p.sessionCount} session`,
      labelAction: "desktop.label",
      switchText: p.isActive ? null : (p.hasAuth ? "Chuyển sang " + (p.label || "account này") : null),
      onSwitch: () => confirmSwitch(p),
    }));
    if (!nodes.length) nodes.push(emptyBox("Chưa có account nào", "Đăng nhập Claude Desktop, công cụ sẽ tự lưu account đầu tiên."));
    setCards(nodes);
    const acts = [];
    if (d.loggedIn) acts.push(btn(d.profiles.length < 2 ? "Thêm account thứ hai" : "Thêm account", "", () => act("desktop.add")));
    $("actions").replaceChildren(...acts);
  }

  function confirmSwitch(p) {
    if (S.status.settings.skipConfirm) return act("desktop.switch", { uuid: p.uuid });
    $("confirmTitle").textContent = "Chuyển sang " + (p.label || "account này") + "?";
    $("confirmText").textContent = "Claude sẽ đóng và mở lại. Việc đang chạy trong Claude (kể cả session Claude Code) sẽ bị dừng.";
    $("confirmSkip").checked = false;
    $("confirm").hidden = false;
    $("confirmYes").focus();
    $("confirmYes").onclick = async () => {
      $("confirm").hidden = true;
      if ($("confirmSkip").checked) await api("/api/action", { action: "settings.set", key: "skipConfirm", value: true }).catch(() => {});
      act("desktop.switch", { uuid: p.uuid });
    };
  }
  $("confirmNo").onclick = () => ($("confirm").hidden = true);

  function renderCli(st) {
    const c = st.cli;
    const overridden = c.authOverrides.length > 0;
    let msg = "Account CLI được quản lý riêng. Hãy thoát các phiên CLI đang chạy trước khi chuyển.";
    let warn = false;
    if (!c.loggedIn) msg = "Đã tìm thấy Claude CLI. Đăng nhập để lưu account đầu tiên.";
    if (c.runningCount > 0) { msg = `Có ${c.runningCount} phiên Claude CLI đang chạy. Thoát CLI trước khi chuyển account; công cụ không tự đóng phiên của bạn.`; warn = true; }
    if (c.unverified) { msg = "Chưa xác minh được account của đăng nhập CLI hiện tại (cần mạng). Công cụ tạm không lưu để tránh lẫn account."; warn = true; }
    if (c.identityMismatch) {
      const real = c.profiles.find((p) => p.uuid === c.activeUuid);
      msg = `CLI thực tế đang đăng nhập ${real && real.label ? real.label : "account khác"}. Tên account trong cấu hình CLI bị Claude Desktop ghi đè nên lệnh claude có thể hiển thị sai; công cụ dùng account thực.`;
      warn = true;
    }
    if (overridden) { msg = "CLI đang dùng cấu hình đăng nhập bên ngoài: " + c.authOverrides.join(", ") + ". Bỏ cấu hình ghi đè để chuyển account tại đây."; warn = true; }
    const pend = c.pendingLogin;
    if (pend && pend.state === "waiting") msg = "Đang chờ bạn đăng nhập trong trình duyệt/cửa sổ CLI. Account hiện tại vẫn được giữ nguyên.";
    if (pend && pend.state === "failed") { msg = "Chưa hoàn tất đăng nhập CLI. Bấm bên dưới để mở lại."; warn = true; }
    info(msg, warn);
    const nodes = c.profiles.map((p) => card(p, {
      fallback: "Account CLI",
      meta: p.authRemovedReason && !p.hasAuth ? "Cần đăng nhập lại" : "",
      labelAction: "cli.label",
      switchText: p.isActive || !p.hasAuth ? null : "Chuyển CLI sang " + (p.label || "account này"),
      disabled: overridden,
      onSwitch: () => act("cli.switch", { uuid: p.uuid }),
    }));
    if (!nodes.length) nodes.push(emptyBox("Chưa có account CLI", "Bấm “Đăng nhập CLI” để lưu account đầu tiên."));
    setCards(nodes);
    const acts = [];
    if (pend && pend.state === "ready") acts.push(btn("Hoàn tất đăng nhập CLI", "primary", () => act("cli.finishLogin")));
    else if (pend && pend.state === "waiting") {
      acts.push(btn("Đang chờ đăng nhập CLI…", "", null, true));
      acts.push(btn("Hủy đăng nhập", "ghost", () => act("cli.cancelLogin")));
    } else acts.push(btn(c.profiles.length ? "Thêm account CLI" : "Đăng nhập CLI", "", () => act("cli.login"), overridden));
    acts.push(btn("Mở Claude CLI", "", () => act("cli.open")));
    $("actions").replaceChildren(...acts);
  }

  function showProgress(title, msg, steps, buttons) {
    $("main").hidden = true;
    $("progress").hidden = false;
    $("progTitle").textContent = title;
    $("progMsg").textContent = msg || "";
    const list = $("progSteps");
    list.replaceChildren(...steps.map(([id, state, text]) => {
      const li = el("li");
      li.dataset.state = state || "pending";
      const icon = { done: "✓", ok: "✓", warn: "!", skipped: "–", error: "✕" }[state] || "";
      li.append(el("span", "dot", icon), el("span", "txt", text || STEP_LABELS[id] || id));
      return li;
    }));
    $("progButtons").replaceChildren(...buttons);
  }

  function renderProgress(job, pending) {
    const order = JOB_STEPS[job.kind] || [];
    const byId = Object.fromEntries(job.steps.map((s) => [s.id, s]));
    const steps = order.map((id) => [id, byId[id] ? byId[id].state : "pending", byId[id] ? byId[id].message : STEP_LABELS[id]]);
    const titles = JOB_TITLES[job.kind] || ["Đang xử lý", "Xong", "Có lỗi"];
    const title = !job.done ? titles[0] : job.ok ? titles[1] : titles[2];
    const buttons = [];
    let msg = job.done ? job.message : "";
    if (job.done && job.kind === "add" && job.ok && pending) {
      msg = "Trong cửa sổ Claude vừa mở, đăng nhập bằng account còn lại. Claude Switch sẽ tự nhận ra và lưu lại.";
      buttons.push(btn("Hủy, quay lại account cũ", "ghost", () => act("desktop.cancelAdd")));
    } else if (job.done) {
      buttons.push(btn(job.ok ? "Xong" : "Đóng", "primary", () => { S.dismissedJob = job.id; render(); }));
    }
    showProgress(title, msg, steps, buttons);
  }

  function renderWaitLogin() {
    showProgress("Hãy đăng nhập account còn lại",
      "Trong cửa sổ Claude, đăng nhập bằng account còn lại. Claude Switch sẽ tự nhận ra và lưu lại.",
      [["close", "done"], ["backup", "done"], ["switch", "done"], ["open", "done"], ["login", "running"]],
      [btn("Hủy, quay lại account cũ", "ghost", () => act("desktop.cancelAdd"))]);
  }

  // ---- menu ------------------------------------------------------------------------------
  const menu = $("menu");
  $("menuBtn").onclick = (ev) => { ev.stopPropagation(); menu.hidden = !menu.hidden; };
  document.addEventListener("click", (ev) => { if (!menu.contains(ev.target)) menu.hidden = true; });
  for (const b of menu.querySelectorAll("[data-action]")) b.onclick = () => { menu.hidden = true; act(b.dataset.action); };
  $("syncChk").onchange = (ev) => act("settings.set", { key: "syncSessions", value: ev.target.checked });
  $("confirmChk").onchange = (ev) => act("settings.set", { key: "skipConfirm", value: !ev.target.checked });
  $("usageBtn").onclick = () => { maybeUsage(true); S.usageBusy = true; render(); };

  refresh().then(() => { maybeUsage(true); schedule(); });
})();

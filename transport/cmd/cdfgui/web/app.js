"use strict";

const $ = (id) => document.getElementById(id);
const state = {
  session: "", page: "overview", snapshot: null, connections: null,
  update: null, pending: false, optionsLoaded: false,
  drafts: {
    time: { dirty: false, edits: 0, revision: "missing", committedAt: 0 },
    proxy: { dirty: false, edits: 0, revision: "missing", committedAt: 0 },
  },
  list: "active", index: 0, stopped: false, activePoll: false, configPoll: false,
  statusVersion: 0, pendingProxy: null, historyVersion: 0, clearing: false,
  browserConsent: null, consentPending: false, consentEpoch: 0,
};
const reasons = {
  finished: "传输结束", "socket-closed": "Socket 关闭", cancelled: "已取消",
  "handshake-failed": "握手失败", "handshake-timeout": "握手超时",
  "bridge-timeout": "本机桥接超时", "forwarding-error": "传输中断", "process-exit": "进程退出",
  "webrtc-blocked": "WebRTC 已拦截",
};
const dnsStatus = {
  ok: "成功", "no-data": "无记录", "blocked-ipv6": "IPv6 已禁用",
  "transport-error": "解析请求失败", "invalid-response": "DNS 响应无效", "buffer-too-small": "缓冲区不足",
  NXDOMAIN: "域名不存在", SERVFAIL: "解析器失败", REFUSED: "解析器拒绝",
};
const roles = {
  desktop: "桌面主进程", "network-service": "Network Service", renderer: "渲染进程",
  "gpu-process": "GPU 进程", "crashpad-handler": "崩溃报告", utility: "辅助进程",
  service: "SYSTEM 服务", helper: "应用助手", unknown: "身份待确认",
};

function put(id, value) { $(id).textContent = value; }
function elem(tag, text, cls) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (cls) node.className = cls;
  return node;
}
function when(date) {
  if (!date || date.startsWith("0001-")) return "—";
  return new Date(date).toLocaleTimeString("zh-CN", { hour12: false });
}
function fmtDate(date) {
  if (!date || date.startsWith("0001-")) return "—";
  return new Date(date).toLocaleString("zh-CN", { hour12: false });
}
function signed(value) { return value > 0 ? "+" + value : String(value); }
function duration(ms) {
  if (!Number.isFinite(ms)) return "—";
  if (ms < 1000) return ms + " ms";
  if (ms < 60000) return (ms / 1000).toFixed(1) + " 秒";
  return Math.floor(ms / 60000) + " 分 " + Math.floor(ms / 1000 % 60) + " 秒";
}
function pill(label, tone) { return elem("span", label, "pill" + (tone ? " " + tone : "")); }
function binary(value, yes, no) {
  if (typeof value !== "boolean") return pill("待确认", "warn");
  return pill(value ? yes : no, value ? "ok" : "");
}
function note(msg, error = false) {
  const el = $("notice");
  el.hidden = !msg;
  el.classList.toggle("error", error);
  el.textContent = msg;
}
function showResult(result) {
  const box = $("result");
  box.replaceChildren();
  box.hidden = !result;
  if (!result) return;
  box.append(elem("strong", result.message || "本地检查结果"));
  if (result.checks) {
    const list = elem("ul");
    for (const check of result.checks) {
      const li = elem("li");
      li.append(pill(check.ok ? "通过" : "未通过", check.ok ? "ok" : "warn"));
      li.append(document.createTextNode(" " + check.name + " · " + check.message));
      list.append(li);
    }
    box.append(list);
  }
}

function feedback(id, message, tone = "", elapsed = "") {
  const box = $(id);
  if (!box.firstChild) {
    const clock = elem("span");
    clock.setAttribute("aria-hidden", "true");
    box.append(elem("span"), clock);
  }
  if (box.firstChild.textContent !== message) box.firstChild.textContent = message;
  if (box.lastChild.textContent !== elapsed) box.lastChild.textContent = elapsed;
  box.dataset.tone = tone;
  box.hidden = !message;
}

function freshFor(group) {
  return (state.update?.snapshotVersion ?? 0) >= state.drafts[group].committedAt;
}

function draftConflict(group) {
  const draft = state.drafts[group];
  return draft.dirty && freshFor(group) && state.snapshot &&
    draft.revision !== state.snapshot[group + "Revision"];
}

function renderDraft(group) {
  const box = $(group + "-draft");
  const conflict = draftConflict(group);
  box.hidden = !state.drafts[group].dirty;
  box.firstElementChild.textContent = conflict ? "已保存的配置已由其他操作更新。当前草稿仍在。" : "有尚未保存的修改。";
  $(group + "-reload").disabled = state.pending || !freshFor(group);
}

function selectedAdapter(guid) {
  return state.snapshot?.adapters?.find((item) => item.guid.toLowerCase() === (guid || "").toLowerCase());
}

async function api(path, method = "GET", payload) {
  const headers = {};
  if (state.session) headers.Authorization = "Bearer " + state.session;
  const yaml = path === "/api/profiles/import" && method === "POST";
  if (method === "POST") headers["Content-Type"] = yaml ? "application/yaml" : "application/json";
  const response = await fetch(path, {
    method, headers, cache: "no-store", credentials: "omit",
    body: method === "POST" ? (yaml ? payload : JSON.stringify(payload || {})) : undefined,
  });
  const result = await response.json();
  if (!response.ok) {
    if (response.status === 401 && path !== "/api/session") {
      state.stopped = true;
      sessionStorage.removeItem("cdf.session");
      controls();
    }
    throw new Error(result.message || "请求失败");
  }
  return result;
}

function selectPage(page) {
  if (!["overview", "settings", "connections"].includes(page)) return;
  state.page = page;
  for (const el of document.querySelectorAll(".page")) el.hidden = el.id !== page;
  for (const tab of document.querySelectorAll(".tab")) {
    if (tab.dataset.page === page) tab.setAttribute("aria-current", "page");
    else tab.removeAttribute("aria-current");
  }
  if (page === "connections") fetchConnections();
  if (page === "settings") refreshProfiles(true);
}

function controls() {
  const d = state.snapshot;
  const connected = Boolean(state.session && !state.stopped && d);
  const available = connected && !state.pending && !state.update?.error;
  const write = available && state.update?.canManage;
  $("check").disabled = !connected || state.pending;
  $("project-switch").disabled = !write;
  $("proxy-switch").disabled = !write || !d?.projectEnabled || !(d?.proxy?.valid || d?.proxyRequested);
  $("webrtc-switch").disabled = !write || !d?.webRTCRevision;
  $("browser-consent-switch").disabled = !write || !state.browserConsent || state.consentPending;
  $("save-time").disabled = !write || !freshFor("time") || draftConflict("time");
  for (const group of ["time", "proxy"]) $(group + "-reload").disabled = !connected || state.pending || !freshFor(group);
  $("preview-time").disabled = !available;
  const usableAdapter = selectedAdapter($("adapter").value)?.up;
  const usableProfile = profileAvailable();
  $("save-proxy").disabled = !write || !usableAdapter || !usableProfile || !freshFor("proxy") || draftConflict("proxy");
  $("test-proxy").disabled = !available || !usableAdapter || !usableProfile;
  profileControls(connected, write);
  $("upgrade").disabled = !write || !d?.proxy?.readable || !selectedAdapter(d?.proxy?.interfaceGuid)?.up;
  $("stop").disabled = !state.session || state.stopped || state.pending;
  $("clear").disabled = !connected || state.clearing || state.list === "active" ||
    !(state.list === "dns" ? state.connections?.dns?.length : state.connections?.closed?.length);
}

function choiceList(parent, rows) {
  const options = rows.map(({ id, label }) => {
    const option = elem("option");
    option.value = id;
    option.label = label;
    return option;
  });
  parent.replaceChildren(...options);
}

function renderSettings(d) {
  const config = d.config;
  const time = config.schemaVersion === 1 ? config : config.time;
  const locale = config.locale || { enabled: false, formatLocale: "en-US", uiLanguage: "en-US" };
  put("schema", "Schema " + config.schemaVersion);
  if (!state.optionsLoaded) {
    choiceList($("timezones"), d.timeZones || []);
    choiceList($("locales"), d.locales || []);
    state.optionsLoaded = true;
  }
  const timeDraft = state.drafts.time;
  if (!timeDraft.dirty && freshFor("time")) {
    $("time-enabled").checked = time.enabled;
    $("timezone").value = time.timeZoneId;
    $("offset").value = time.utcOffsetSeconds;
    $("locale-enabled").checked = locale.enabled;
    $("format-locale").value = locale.formatLocale;
    $("ui-language").value = locale.uiLanguage;
    timeDraft.revision = d.timeRevision;
  }
  $("migration").hidden = config.schemaVersion !== 1 || !$("locale-enabled").checked;
  const adapter = $("adapter");
  const proxyDraft = state.drafts.proxy;
  const readSaved = !proxyDraft.dirty && freshFor("proxy");
  const available = d.adapters || [];
  const initial = !d.proxy.configured && !d.proxy.interfaceGuid ? available.find((item) => item.up)?.guid : "";
  const wanted = (readSaved ? d.proxy.interfaceGuid || initial : proxyDraft.adapterGuid) || "";
  if (readSaved) proxyDraft.adapterGuid = wanted;
  const chosen = selectedAdapter(wanted);
  const adapterSignature = JSON.stringify(available);
  if (adapter.dataset.signature !== adapterSignature) {
    const items = [];
    for (const option of available) {
      const item = new Option(option.name + (option.up ? "" : "（已离线）"), option.guid);
      item.disabled = !option.up;
      items.push(item);
    }
    adapter.replaceChildren(...items);
    adapter.dataset.signature = adapterSignature;
  }
  adapter.value = chosen?.guid || "";
  adapter.disabled = !available.length;
  const deployed = d.proxy.interfaceGuid || "";
  let adapterNote = "";
  if (wanted && !chosen?.up) {
    adapterNote = (chosen ? "所选网卡已离线。" : "未找到已选网卡 " + wanted + "。") + "请连接原网卡，或明确选择替代网卡后保存。";
  } else if (chosen && deployed && chosen.guid.toLowerCase() !== deployed.toLowerCase()) {
    adapterNote = "待保存的网卡变更　" + (selectedAdapter(deployed)?.name || deployed) + " → " + chosen.name;
  } else if (!wanted) {
    adapterNote = available.length ? "请选择本次要使用的物理网卡。" : "没有可选的物理网卡。";
  }
  feedback("adapter-note", adapterNote, "warn");
  if (readSaved) {
    proxyDraft.revision = d.proxyRevision;
  }
  put("proxy-config-state", d.proxy.valid ? "部署已校验" : d.proxy.configured ? "需检查" : "尚未配置");
  $("upgrade-note").hidden = !d.proxy.upgradeAvailable;
  renderWebRTC(d);
  renderProfilePicker(d, readSaved);
  renderDraft("time");
  renderDraft("proxy");
}

function renderWebRTC(d) {
  $("webrtc-switch").setAttribute("aria-checked", String(d.webRTCDisabled !== false));
  let description = d.webRTCDisabled !== false ? "已配置禁用。" : "已配置关闭 WebRTC 禁用。";
  if (!d.proxy.supportsConnections) description += "新版传输加载后应用。";
  else if (d.webRTCDisabled !== false) description += "新建代理连接会拦截可识别的 STUN/TURN。";
  description += " 测试浏览器支持会话级禁用，Claude 桌面端的会话级状态未验证。";
  put("webrtc-detail", description);
  put("ipv6-policy", d.proxy.ipv4Only ? "网络 Hook 已部署 IPv4 策略。UDP 始终拒绝。" :
    "升级网络组件后，Hook 将限制为 IPv4。UDP 拒绝独立于 WebRTC 开关。");
}

function emptyRow(body, text, columns) {
  const tr = elem("tr");
  const td = elem("td", text, "empty");
  td.colSpan = columns;
  tr.append(td);
  body.replaceChildren(tr);
}

function pidLink(pid) {
  const button = elem("button", "PID " + pid, "text-button pid-link");
  button.type = "button";
  button.dataset.pid = String(pid);
  button.setAttribute("aria-label", "查看 PID " + pid + " 的连接记录");
  return button;
}

// Narrow tables keep the first and last column. Their middle cells also
// supply the expandable details, so desktop and narrow views use the same data.
function replaceTableRows(body, rows) {
  const opened = new Set(Array.from(body.querySelectorAll("details[open]"), (el) => el.closest("tr").dataset.key));
  const focused = document.activeElement;
  const focusRow = body.contains(focused) ? focused.closest("tr")?.dataset.key : null;
  const labels = body.closest("table").tHead.rows[0].cells;
  let restoreFocus;
  for (const row of rows) {
    const details = elem("details", undefined, "row-details");
    const summary = elem("summary", "详情");
    details.append(summary);
    for (let index = 1; index < row.cells.length - 1; index++) {
      const item = elem("div");
      item.append(elem("strong", labels[index].textContent + " "));
      for (const node of row.cells[index].childNodes) item.append(node.cloneNode(true));
      details.append(item);
    }
    details.open = opened.has(row.dataset.key);
    row.cells[0].append(details);
    if (row.dataset.key === focusRow) restoreFocus = focused.matches("summary") ? summary : row.querySelector(".pid-link");
  }
  body.replaceChildren(...rows);
  restoreFocus?.focus({ preventScroll: true });
}

function renderProxy(d) {
  const proxy = $("proxy-switch");
  proxy.setAttribute("aria-checked", String(d.proxyRequested));
  proxy.setAttribute("aria-busy", String(Boolean(state.pendingProxy)));
  if (state.pendingProxy) {
    put("proxy-value", state.pendingProxy.enabled ? "正在开启…" : "正在关闭…");
  } else {
    put("proxy-value", d.proxyEnabled ? "已登记" : d.proxyRequested ? "待确认" : "已关闭");
  }
  const selected = d.adapters.find((item) => item.guid.toLowerCase() === d.proxy.interfaceGuid?.toLowerCase());
  const proxyReady = d.processes.filter((p) => p.transportReady).length;
  put("proxy-detail", (selected ? selected.name + " · " : "") +
    (proxyReady ? proxyReady + (d.proxyRequested ? " 个进程传输就绪" : " 个已运行进程仍使用代理") :
      d.proxy.valid ? "代理配置已校验" : "代理配置待检查"));
}

function renderOverview(d) {
  const config = d.config;
  const time = config.schemaVersion === 1 ? config : config.time;
  const locale = config.locale;
  $("project-switch").setAttribute("aria-checked", String(d.projectEnabled));
  put("project-value", d.projectEnabled ? "已启用" : d.projectManaged ? "登记冲突" : "已关闭");
  put("project-detail", d.monitorRunning ? "开机自动刷新运行中" : d.monitorEnabled ? "自动刷新等待心跳" : "开机自动刷新已关闭");
  renderProxy(d);
  put("env-value", time.enabled ? time.timeZoneId : "时间 Hook 已关闭");
  put("env-detail", locale?.enabled ? locale.formatLocale + " · UI " + locale.uiLanguage : "语言 Hook 已关闭");
  const childScope = d.networkChildTargets;
  const children = childScope?.running || [];
  const managedPids = new Set(d.processes.map((p) => p.pid));
  const externalChildren = children.filter((p) => !managedPids.has(p.pid));
  const childSummary = $("child-targets");
  childSummary.hidden = !childScope;
  if (childScope) {
    const scopeStatus = {
      complete: "本次识别 " + children.length + " 个",
      partial: "部分 Claude 身份无法核实",
      "no-manifest": "等待 Claude 身份清单",
      unavailable: "读取失败",
    };
    childSummary.textContent = [
      "Claude 子进程清单", (childScope.imageNames || []).join("、"),
      scopeStatus[childScope.inspection], childScope.error, "尚未配置强制代理",
    ].filter(Boolean).join(" · ");
  }
  put("process-updated", "最近检查 " + when(state.update.updated) + " · " + (d.processes.length + externalChildren.length) + " 个进程");
  const counts = [["已登记", "registered"], ["网络 Provider 已加载", "networkLoaded"], ["传输就绪", "transportReady"], ["待重启", "needsRestart"]];
  const summary = counts.map(([label, key]) => label + " " + d.processes.filter((p) => p[key] === true).length);
  const unknown = d.processes.filter((p) => counts.some(([, key]) => typeof p[key] !== "boolean")).length;
  if (unknown) summary.push("待完整核实 " + unknown);
  put("process-counts", summary.join(" · "));
  $("process-counts").hidden = d.processes.length === 0;
  const tbody = $("processes");
  if (!d.processes.length && !children.length) {
    emptyRow(tbody, "没有运行中的目标进程", 5);
  } else {
    const rows = d.processes.map((p) => {
      const tr = elem("tr");
      tr.dataset.key = p.pid + "/" + (p.created || "");
      const process = elem("td", p.name, "first-col");
      const identity = elem("span", (roles[p.role] || p.role || "进程") + " · ", "subline");
      identity.append(pidLink(p.pid));
      process.append(identity);
      if (p.needsRestart) process.append(elem("span", "下次启动生效", "subline"));
      if (p.error) process.append(elem("span", p.error, "subline"));
      const registered = elem("td");
      registered.append(binary(p.registered, "已登记", "未登记"));
      const loaded = elem("td");
      if (typeof p.timeLoaded === "boolean") {
        loaded.append(pill([p.timeLoaded && "时间", p.networkLoaded && "网络"].filter(Boolean).join(" + ") || "未加载",
          p.timeLoaded || p.networkLoaded ? "ok" : ""));
      } else {
        loaded.append(pill("待确认", "warn"));
      }
      const features = elem("td");
      features.append(binary(p.timeReady, "时间就绪", "时间未启用"), binary(p.localeReady, "语言就绪", "语言未启用"));
      const network = elem("td");
      network.append(p.transportReady ? pill("传输就绪", "ok") :
        p.networkHooksReady ? pill("Hook 已就绪，等待连接", "warn") :
        binary(p.networkHooksReady, "就绪", "未就绪"));
      tr.append(process, registered, loaded, features, network);
      return tr;
    });
    for (const child of externalChildren) {
      const tr = elem("tr");
      tr.dataset.key = "child/" + child.pid;
      const name = elem("td", child.name, "first-col");
      const identity = elem("span", undefined, "subline");
      identity.append(pidLink(child.pid), document.createTextNode(" · 来自 Claude PID " + child.claudePid));
      name.append(identity);
      const policy = elem("td");
      policy.append(pill("未强制代理", "warn"));
      tr.append(name, elem("td", "子进程清单"), elem("td", "—"), elem("td", "—"), policy);
      rows.push(tr);
    }
    replaceTableRows(tbody, rows);
  }
  const issues = $("issues");
  issues.replaceChildren(...(d.issues || []).map((message) => elem("li", message)));
  issues.hidden = !d.issues?.length;
}

async function refresh() {
  if (!state.session || state.stopped || state.configPoll) return;
  state.configPoll = true;
  const consentEpoch = state.consentEpoch;
  try {
    const result = await api("/api/status");
    if (result.statusVersion < state.statusVersion) return;
    state.statusVersion = result.statusVersion;
    state.update = result;
    if (consentEpoch === state.consentEpoch && !state.consentPending) state.browserConsent = result.browserConsent || null;
    renderBrowserConsent(result.data);
    put("local", "本机 · " + new URL(result.origin).port);
    $("local").classList.add("online");
    put("footer-address", result.origin + (result.fallback ? " · 已自动切换端口" : ""));
    const gui = result.gui;
    if (gui) {
      const id = (s) => s.slice(0, 12);
      let version = "界面 " + id(gui.build);
      if (gui.runningRelease) {
        version += " · 运行发行版 " + id(gui.runningRelease);
        if (!gui.selectedRelease) version += " · 无法核实已选发行版";
        else if (gui.selectedRelease !== gui.runningRelease) version += " · 下次启动控制台将使用 " + id(gui.selectedRelease);
      } else version += " · 工作区";
      put("gui-version", version);
    }
    if (result.data) {
      state.snapshot = result.data;
      renderOverview(result.data);
      renderSettings(result.data);
      if (state.page === "settings") refreshProfiles();
    }
    note(result.error || (!result.canManage ? "当前为只读模式。使用管理员 PowerShell 运行启动脚本可安装管理组件。" : ""), Boolean(result.error));
  } catch (error) {
    note(error.message || "本机服务暂时不可用", true);
    $("local").classList.remove("online");
    if (state.update) state.update.error = error.message;
  } finally {
    state.configPoll = false;
    controls();
  }
}

function renderBrowserConsent(data) {
  const policy = state.browserConsent;
  $("browser-consent-switch").setAttribute("aria-checked", String(Boolean(policy?.enabled)));
  let note = "当前用户已关闭询问。";
  if (!policy) note = "尚未读取到设置。";
  else if (policy.error) note = policy.error;
  else if (policy.enabled) {
    if (!data?.browserConsentProviderCurrent) note = "已开启询问。需要部署本版 Claude 组件并重新打开 Claude，弹窗才会生效。";
    else if (!data.projectEnabled) note = "已开启询问。启用项目登记后，新启动的受管理 Claude 进程会使用此设置。";
    else note = "已开启询问，适用于已加载本版组件的 Claude 进程。";
  }
  put("browser-consent-note", note);
}

async function switchBrowserConsent() {
  if ($("browser-consent-switch").disabled) return;
  state.consentPending = true;
  state.consentEpoch++;
  controls();
  feedback("browser-consent-feedback", "正在保存…");
  try {
    state.browserConsent = await api("/api/browser-consent", "POST", {enabled: !state.browserConsent.enabled});
    renderBrowserConsent(state.snapshot);
    feedback("browser-consent-feedback", "设置已保存。", "ok");
  } catch (error) {
    feedback("browser-consent-feedback", error.message, "error");
  } finally {
    state.consentEpoch++;
    state.consentPending = false;
    controls();
  }
}

function renderConnections() {
  const data = state.connections;
  if (!data) return;
  const warnings = [];
  const isDNS = state.list === "dns";
  const dnsRows = data.dns || [];
  const dnsUpgrade = isDNS && !data.dnsSources && state.snapshot?.proxy.upgradeAvailable;
  const legacy = state.snapshot?.proxy.upgradeAvailable && !data.sources;
  const nameUpgrade = state.snapshot?.proxy.upgradeAvailable && !data.nameSources && data.sources;
  $("connection-upgrade").hidden = !legacy && !nameUpgrade && !dnsUpgrade;
  if (dnsUpgrade) {
    warnings.push("升级网络组件后，新进程会提供 Hook 处理的 DNS 查询。");
  } else if (legacy) {
    warnings.push("当前传输尚未提供逐条事件。退出使用代理的进程，在配置页升级传输组件，再打开应用以开始记录。");
  } else if (nameUpgrade) {
    warnings.push("当前传输正在记录 IP。升级传输组件并重新打开应用后，连接页会显示可见的目标域名。");
  } else if (data.waiting) {
    warnings.push(data.waiting + " 个已使用代理的进程等待连接采集。");
  }
  if (isDNS ? data.dnsGaps : data.gaps) warnings.push("部分事件超出传输缓存容量。");
  put("connection-note", warnings.join(" "));
  $("connection-note").hidden = warnings.length === 0;
  const sources = isDNS ? data.dnsSources : data.sources;
  put("connection-updated", sources ? "最近采集 " + when(data.updated) + " · " + sources + " 个采集来源" :
    legacy || dnsUpgrade ? "需要升级网络组件" : "等待代理传输进程");
  put("active-count", data.sources || data.active.length ? data.active.length : "—");
  put("closed-count", data.closed.length);
  put("dns-count", data.dnsSources || dnsRows.length ? dnsRows.length : "—");
  $("clear").hidden = state.list === "active";
  put("clear", "清除全部 " + (isDNS ? dnsRows.length + " 条 DNS 记录" : data.closed.length + " 条已关闭记录"));
  put("connection-host-column", isDNS ? "域名 / 类型" : "域名 / 地址与端口");
  put("connection-time-column", isDNS ? "查询完成时间" : "开始时间");
  put("connection-result-column", isDNS ? "状态 / IPv4 结果" : "状态 / 原因");
  const value = $("filter").value.trim().toLowerCase();
  const allRows = isDNS ? dnsRows : data[state.list];
  const pid = /^pid:\s*(\d+)$/.exec(value);
  const rows = allRows.filter((r) => pid ? String(r.pid) === pid[1] : !value || (isDNS ?
    [r.name, r.type, ...(r.addresses || []), r.process, r.pid, dnsStatus[r.status] || r.status] :
    [r.serverName, r.target, r.port, r.name, r.pid, r.role]).join(" ").toLowerCase().includes(value));
  const counts = [];
  if (value) counts.push("匹配 " + rows.length + " / 共 " + allRows.length);
  if (state.list === "active" && (data.sources || rows.length)) {
    counts.push("转发中 " + rows.filter((r) => !r.stale && r.state === "active").length,
      "建立中 " + rows.filter((r) => !r.stale && r.state === "connecting").length,
      "采集暂离 " + rows.filter((r) => r.stale).length);
  }
  put("connection-counts", counts.join(" · "));
  $("connection-counts").hidden = counts.length === 0;
  const pages = Math.max(1, Math.ceil(rows.length / 30));
  state.index = Math.min(state.index, pages - 1);
  const body = $("connection-rows");
  if (!rows.length) {
    emptyRow(body, value ? "没有符合筛选条件的记录" : isDNS ?
      data.dnsSources ? "本次会话尚无 DNS 查询" : "等待支持 DNS 记录的代理进程" : state.list === "closed" ?
      "本次会话尚无已关闭连接" : data.sources ? "当前没有活跃连接" :
      legacy ? "当前传输尚无逐条连接记录" : "等待代理产生连接", 5);
  } else {
    replaceTableRows(body, rows.slice(state.index * 30, state.index * 30 + 30).map((r) => {
      const tr = elem("tr");
      tr.dataset.key = state.list + "/" + (r.key || [r.pid, r.cursor ?? r.id, r.finished || r.started, r.name, r.type].join("/"));
      if (isDNS) {
        const query = elem("td", r.name, "mono");
        query.append(elem("span", r.type, "subline"));
        query.append(elem("span", "PID " + r.pid, "narrow-pid"));
        const process = elem("td", r.process);
        process.append(elem("span", (roles[r.role] || r.role) + " · " + r.pid, "subline"));
        const result = elem("td");
        result.append(pill(dnsStatus[r.status] || r.status, r.status === "ok" ? "ok" : "warn"));
        if (r.addresses?.length) result.append(elem("span", r.addresses.join(" · "), "subline"));
        tr.append(query, process, elem("td", fmtDate(r.finished)), elem("td", duration(r.durationMs)), result);
        return tr;
      }
      const endpoint = (r.target.includes(":") ? "[" + r.target + "]" : r.target) + ":" + r.port;
      const target = elem("td", r.serverName ? r.serverName + ":" + r.port : endpoint, "mono");
      if (r.serverName && r.serverName !== r.target.toLowerCase()) {
        target.append(elem("span", endpoint + " · TLS", "subline"));
      }
      const process = elem("td", r.name);
      target.append(elem("span", "PID " + r.pid, "narrow-pid"));
      process.append(elem("span", (roles[r.role] || r.role) + " · " + r.pid, "subline"));
      const status = elem("td");
      const text = r.stale ? "采集暂离" : r.state === "active" ? "正在转发" : r.state === "connecting" ? "建立中" : reasons[r.reason] || "已关闭";
      status.append(pill(text, r.stale || r.state === "connecting" ? "warn" : r.state === "active" ? "ok" : ""));
      tr.append(target, process, elem("td", fmtDate(r.started)), elem("td", duration(r.durationMs)), status);
      return tr;
    }));
  }
  $("pagination").hidden = pages <= 1;
  $("prev").disabled = state.index === 0;
  $("next").disabled = state.index === pages - 1;
  put("page-number", (state.index + 1) + " / " + pages);
}

async function fetchConnections() {
  if (!state.session || state.stopped || state.activePoll || state.clearing || state.page !== "connections") return;
  state.activePoll = true;
  const version = state.historyVersion;
  try {
    const next = await api("/api/connections");
    if (version !== state.historyVersion) return;
    state.connections = next;
    renderConnections();
  } catch (error) {
    if (version !== state.historyVersion) return;
    put("connection-note", "连接列表读取失败 · " + error.message);
    $("connection-note").hidden = false;
  } finally {
    state.activePoll = false;
    controls();
  }
}

function renderPreview(result, id) {
  const box = $(id);
  const lines = [];
  if (id === "time-preview") {
    lines.push(["目标当地时间", result.virtualLocalTime || "时间 Hook 已关闭"]);
    if (result.virtualLocalTime) {
      lines.push(["时区偏移", "UTC " + signed(result.timeZoneOffsetSeconds) + " 秒 · " + (result.daylightSavingTime ? "夏令时" : "标准时")]);
      lines.push(["额外 UTC 偏移", signed(result.utcClockShiftSeconds) + " 秒"]);
    }
    if (result.locale) lines.push(["区域示例", [result.locale.date, result.locale.number, result.locale.currency].join(" · ")]);
  } else {
    lines.push(["出口 IP", result.ip], ["代理网卡", result.interfaceName], ["耗时", duration(result.durationMs)]);
  }
  box.replaceChildren(...lines.map(([label, value]) => {
    const row = elem("p");
    row.append(elem("strong", label + "　"), document.createTextNode(value));
    return row;
  }));
  box.hidden = false;
}

const taskUI = {
  "check": ["检查配置", "result"],
  "project.switch": ["项目登记", "project-feedback"],
  "proxy.switch": ["代理登记", "network-feedback"],
  "webrtc.switch": ["保存 WebRTC 策略", "webrtc-feedback"],
  "time.preview": ["预览时区与语言", "time-feedback"],
  "time.save": ["保存时区与语言", "time-feedback"],
  "proxy.test": ["测试代理出口", "proxy-feedback"],
  "proxy.save": ["保存代理", "proxy-feedback"],
};
const jobPhases = {
  queued: "后台已接收", manager: "等待管理组件", authorization: "等待管理员授权", executing: "正在执行",
};

async function task(value) {
  if (!value || state.pending || state.stopped) return;
  const [title, target] = value.upgrade ? ["升级网络组件", "upgrade-feedback"] : taskUI[value.action];
  const group = value.action.startsWith("time.") ? "time" : value.action.startsWith("proxy.") ? "proxy" : null;
  const draft = group && state.drafts[group];
  const submittedEdits = draft?.edits;
  const started = Date.now();
  let phase = "正在提交";
  function report(message, tone, elapsed = "") {
    if (target === "result" && $("result").dataset.view !== "feedback") {
      $("result").replaceChildren();
      $("result").dataset.view = "feedback";
    }
    feedback(target, message, tone, elapsed);
  }
  const tick = () => report(title + " · " + phase, "pending", " · " + Math.floor((Date.now() - started) / 1000) + " 秒");
  state.pending = true;
  if (value.action === "proxy.switch") {
    state.pendingProxy = { enabled: value.enabled };
    renderProxy(state.snapshot);
  }
  controls();
  tick();
  const timer = setInterval(tick, 1000);
  try {
    let job = await api("/api/actions", "POST", value);
    while (job.state === "running") {
      phase = jobPhases[job.phase] || "后台已接收";
      tick();
      await new Promise((resolve) => setTimeout(resolve, 550));
      job = await api("/api/jobs/" + job.id);
    }
    if (job.statusVersion >= state.statusVersion) {
      state.statusVersion = job.statusVersion;
      if (typeof job.result?.proxyEnabled === "boolean" && typeof job.result?.proxyRequested === "boolean") {
        state.snapshot.proxyEnabled = job.result.proxyEnabled;
        state.snapshot.proxyRequested = job.result.proxyRequested;
      }
      if (typeof job.result?.webRTCDisabled === "boolean") {
        state.snapshot.webRTCDisabled = job.result.webRTCDisabled;
        state.snapshot.webRTCRevision = job.result.webRTCRevision;
        renderWebRTC(state.snapshot);
      }
    }
    if (job.state !== "done") throw new Error(job.message || "操作失败");
    const unchanged = submittedEdits === draft?.edits;
    let message = job.result.message || (title + "已完成。");
    if (value.action === "time.save" || value.action === "proxy.save") {
      const receipt = job.result[group + "Revision"];
      if (!receipt) throw new Error("后台已完成操作，未返回保存版本。请核对已保存的配置，当前草稿已保留。");
      // Only advance the base to this operation's own receipt. A subsequent
      // full snapshot may belong to another writer and must still conflict.
      if (!value.upgrade || draft.revision === value.revision) draft.revision = receipt;
      draft.committedAt = job.statusVersion;
      if (!value.upgrade) {
        draft.dirty = !unchanged;
        if (!unchanged) {
          message = group === "time" ? "已保存本次提交（额外 UTC 偏移 " + value.time.utcOffsetSeconds + " 秒）。后续修改仍在草稿中。" :
            "已保存本次提交的代理配置。后续修改仍在草稿中。";
        }
        if (group === "proxy" && value.profileId) profileApplied(value.profileId);
      }
    }
    if (target === "result") {
      $("result").dataset.view = "checks";
      delete $("result").dataset.tone;
      showResult(job.result);
    } else {
      report(message, "ok");
    }
    if (job.result.preview && (group === "time" ? unchanged : !state.drafts.time.dirty)) renderPreview(job.result.preview, "time-preview");
    if (value.action === "proxy.test" && unchanged) renderPreview(job.result, "proxy-preview");
  } catch (error) {
    report(title + " · " + error.message, "error");
  } finally {
    clearInterval(timer);
    state.pending = false;
    if (state.pendingProxy) {
      state.pendingProxy = null;
      renderProxy(state.snapshot);
    }
    if (group) renderDraft(group);
    controls();
    refresh();
  }
}

function timeFields(action) {
  if (!$("time-form").reportValidity()) return null;
  const offset = Number($("offset").value);
  if (!Number.isSafeInteger(offset)) {
    feedback("time-feedback", "请输入整数秒的 UTC 偏移。", "error");
    return null;
  }
  return {
    action, revision: state.drafts.time.revision,
    time: { enabled: $("time-enabled").checked, timeZoneId: $("timezone").value.trim(), utcOffsetSeconds: offset },
    locale: { enabled: $("locale-enabled").checked, formatLocale: $("format-locale").value.trim(), uiLanguage: $("ui-language").value.trim() },
  };
}

function proxyFields(action) {
  if (!$("proxy-form").reportValidity()) return null;
  if (!selectedAdapter($("adapter").value)?.up) return null;
  if (!profileAvailable()) return null;
  return { action, revision: state.drafts.proxy.revision, profileId: $("proxy-profile").value,
    proxy: { interfaceGuid: $("adapter").value } };
}

function selectList(tab) {
  state.list = tab;
  state.index = 0;
  for (const item of ["active", "closed", "dns"]) $("show-" + item).setAttribute("aria-pressed", String(tab === item));
  feedback("history-feedback", "");
  renderConnections();
  controls();
}

function wire() {
  wireProfiles();
  $("browser-consent-switch").addEventListener("click", switchBrowserConsent);
  document.querySelectorAll("[data-page]").forEach((link) => link.addEventListener("click", (event) => {
    event.preventDefault();
    selectPage(link.dataset.page);
    history.replaceState(null, "", "#" + link.dataset.page);
  }));
  $("check").addEventListener("click", () => task({ action: "check" }));
  $("project-switch").addEventListener("click", () => task({ action: "project.switch", enabled: !state.snapshot.projectEnabled }));
  $("proxy-switch").addEventListener("click", () => {
    const enabled = !state.snapshot.proxyRequested;
    task({ action: "proxy.switch", enabled });
  });
  $("webrtc-switch").addEventListener("click", () => {
    const d = state.snapshot;
    task({ action: "webrtc.switch", enabled: d.webRTCDisabled === false, revision: d.webRTCRevision });
  });
  $("connection-upgrade").addEventListener("click", () => {
    selectPage("settings");
    history.replaceState(null, "", "#settings");
    $("upgrade-note").scrollIntoView({ block: "center" });
  });
  for (const group of ["time", "proxy"]) {
    const draft = state.drafts[group];
    $(group + "-form").addEventListener("input", (event) => {
      if (event.target.id === "adapter") draft.adapterGuid = $("adapter").value;
      if (event.target.id === "proxy-profile") profilePicker.selected = $("proxy-profile").value;
      draft.edits++;
      draft.dirty = true;
      $(group + "-preview").hidden = true;
      if (!state.pending) feedback(group + "-feedback", "");
      if (state.snapshot) renderSettings(state.snapshot);
      controls();
    });
    $(group + "-reload").addEventListener("click", () => {
      draft.dirty = false;
      draft.edits++;
      $(group + "-preview").hidden = true;
      feedback(group + "-feedback", "");
      renderSettings(state.snapshot);
      controls();
    });
    $(group + "-form").addEventListener("submit", (event) => {
      event.preventDefault();
      if ($("save-" + group).disabled) return;
      task(group === "time" ? timeFields("time.save") : proxyFields("proxy.save"));
    });
  }
  $("preview-time").addEventListener("click", () => task(timeFields("time.preview")));
  $("test-proxy").addEventListener("click", () => task(proxyFields("proxy.test")));
  $("upgrade").addEventListener("click", () => {
    const current = state.snapshot.proxy;
    const request = { action: "proxy.save", revision: state.snapshot.proxyRevision, upgrade: true,
      proxy: { interfaceGuid: current.interfaceGuid, reuse: true } };
    task(request);
  });
  const tabs = ["active", "closed", "dns"];
  for (const tab of tabs) {
    $("show-" + tab).addEventListener("click", () => selectList(tab));
  }
  $("processes").addEventListener("click", (event) => {
    const link = event.target.closest("button[data-pid]");
    if (!link) return;
    $("filter").value = "pid:" + link.dataset.pid;
    selectList("active");
    selectPage("connections");
    history.replaceState(null, "", "#connections");
    $("filter").focus();
  });
  $("filter").addEventListener("input", () => { state.index = 0; renderConnections(); });
  $("prev").addEventListener("click", () => { state.index--; renderConnections(); });
  $("next").addEventListener("click", () => { state.index++; renderConnections(); });
  $("clear").addEventListener("click", async () => {
    if (state.clearing || state.list === "active") return;
    const key = state.list;
    state.clearing = true;
    state.historyVersion++;
    controls();
    try {
      await api(key === "dns" ? "/api/dns/clear" : "/api/connections/clear", "POST");
      state.connections[key] = [];
      if (key === "dns") state.connections.dnsGaps = false;
      feedback("history-feedback", key === "dns" ? "已清除全部 DNS 记录。" : "已清除全部已关闭记录。", "ok");
      renderConnections();
    } catch (error) { feedback("history-feedback", error.message, "error"); }
    finally {
      state.clearing = false;
      controls();
      fetchConnections();
    }
  });
  $("stop").addEventListener("click", async () => {
    try {
      await api("/api/stop", "POST");
      state.stopped = true;
      sessionStorage.removeItem("cdf.session");
      $("local").classList.remove("online");
      put("local", "控制台已停止");
      note("再次运行启动脚本可打开控制台。");
      controls();
    } catch (error) { note(error.message, true); }
  });
}

async function initialize() {
  wire();
  const hash = location.hash.slice(1);
  const ticket = new URLSearchParams(hash).get("ticket");
  try {
    if (ticket) {
      history.replaceState(null, "", "/");
      state.session = (await api("/api/session", "POST", { ticket })).session;
      sessionStorage.setItem("cdf.session", state.session);
    } else {
      state.session = sessionStorage.getItem("cdf.session") || "";
      selectPage(hash);
    }
    if (!state.session) throw new Error("请运行 Start-Gui.ps1 获取本地打开票据。");
    controls();
    await refresh();
    setInterval(refresh, 2500);
    setInterval(fetchConnections, 1000);
  } catch (error) {
    note(error.message, true);
  }
}

initialize();

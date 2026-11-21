// End-to-end dashboard regressions. Only the fixture's loopback HTTP server receives requests.
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { once } = require("node:events");
const { setTimeout: wait } = require("node:timers/promises");
const test = require("node:test");

const web = path.resolve(__dirname, "../transport/cmd/cdfgui/web");
const rev = (n) => n.toString(16).padStart(64, "0");
const wired = "{00000000-0000-0000-0000-000000000001}";
const wifi = "{00000000-0000-0000-0000-000000000002}";
const stamp = "2026-01-01T12:00:00Z";
function processRow(pid) {
  return { pid, name: "fixture.exe", role: "desktop", registered: true, networkLoaded: true,
    timeLoaded: true, timeReady: true, localeReady: true, networkHooksReady: true,
    needsRestart: pid === 420, transportReady: pid === 42 };
}
function connection(pid, state, stale = false) {
  return { key: pid + "/" + state, pid, state, stale, target: "192.0.2.1", port: 443,
    name: "fixture.exe", serverName: "fixture-" + pid + ".example", role: "utility", started: stamp, durationMs: 62 };
}

function fixture() {
  const data = {
    projectEnabled: true, proxyEnabled: true, proxyRequested: true, monitorRunning: true,
    timeRevision: rev(1), proxyRevision: rev(2), webRTCRevision: rev(3), webRTCDisabled: true,
    config: {schemaVersion: 3, time: {enabled: true, timeZoneId: "Pacific Standard Time", utcOffsetSeconds: 0},
      locale: {enabled: true, formatLocale: "en-US", uiLanguage: "en-US"}},
    adapters: [{guid: wired, name: "Ethernet", up: false}, {guid: wifi, name: "Wi-Fi", up: true}],
    proxy: {valid: true, configured: true, readable: true, interfaceGuid: wired, server: "192.0.2.2", port: 443,
      supportsConnections: true, ipv4Only: true},
    processes: [processRow(42), processRow(420)], issues: [],
  };
  const status = {data, updated: stamp, canManage: true, statusVersion: 0, snapshotVersion: 0, browserConsent:{enabled:false},
    gui: {build: "A".repeat(64), runningRelease: "B".repeat(64), selectedRelease: "C".repeat(64)}};
  const history = {updated: stamp, sources: 1, nameSources: 1, dnsSources: 1,
    active: [connection(42, "connecting"), connection(420, "connecting"), connection(17, "active", true)],
    closed: [connection(42, "closed"), connection(420, "closed")],
    dns: [{pid: 42, name: "sample.example", process: "fixture.exe", type: "A", status: "ok", finished: stamp}]};
  const catalog = {profiles:[
    {id:"a1", name:"日常代理", server:"192.0.2.2", port:443},
    {id:"b2", name:"Travel", server:"192.0.2.8", port:8443},
  ], activeId:"a1"};
  const api = { data, status, history, catalog, submissions: [], catalogWrites: [], job: null };
  api.server = http.createServer(async (req, res) => {
    const send = (obj) => { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(obj)); };
    if (["/", "/app.js", "/profiles.js", "/app.css", "/icon.svg"].includes(req.url)) {
      const file = req.url === "/" ? "index.html" : req.url.slice(1);
      res.setHeader("Content-Type", {".html":"text/html", ".js":"text/javascript", ".css":"text/css", ".svg":"image/svg+xml"}[path.extname(file)] + "; charset=utf-8");
      return res.end(fs.readFileSync(path.join(web, file)));
    }
    if (req.url === "/api/session") return send({session: "fixture-only"});
    if (req.url === "/api/status") return send(status);
    if (req.url === "/api/connections") return send(history);
    if (req.url === "/api/browser-consent" && req.method === "POST") {
      let body = "";
      for await (const part of req) body += part;
      const payload = JSON.parse(body);
      assert.deepEqual(Object.keys(payload),["enabled"]);
      status.browserConsent = {enabled:payload.enabled};
      return send(status.browserConsent);
    }
    if (req.url === "/api/profiles" && req.method === "GET") return send(catalog);
    if (req.url.startsWith("/api/profiles") && req.method === "POST") {
      let body = "";
      for await (const part of req) body += part;
      api.catalogWrites.push({path:req.url, type:req.headers["content-type"], body});
      if (req.url.endsWith("/import")) {
        const item = {id:"imported", name:"YAML 示例", server:"192.0.2.7", port:443};
        catalog.profiles.push(item);
        return send({...catalog, selected:item.id, imported:1, skipped:1});
      }
      const p = JSON.parse(body);
      if (catalog.profiles.some((old) => old.name.toLowerCase() === p.name.toLowerCase() && old.id !== p.id)) {
        res.statusCode = 409;
        return send({message:"配置名称已存在（忽略大小写）"});
      }
      if (req.url.endsWith("/rename")) {
        catalog.profiles.find((old) => old.id === p.id).name = p.name;
        return send({...catalog, selected:p.id});
      }
      const item = {id:"manual", name:p.name, server:p.values.server, port:p.values.port};
      catalog.profiles.push(item);
      return send({...catalog, selected:item.id});
    }
    if (req.url === "/api/actions") {
      let body = "";
      for await (const part of req) body += part;
      api.submissions.push(JSON.parse(body));
      api.job = {id: String(api.submissions.length), state: "running", phase: "queued"};
      return send(api.job);
    }
    if (req.url === "/api/jobs/" + api.job?.id) return send(api.job);
    if (req.url === "/api/connections/clear") { history.closed = []; return send({cleared: true}); }
    if (req.url === "/api/dns/clear") { history.dns = []; return send({cleared: true}); }
    res.writeHead(404); res.end();
  });
  return api;
}

async function until(probe, label) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (await probe()) return;
    await wait(70);
  }
  throw Error("Timed out: " + label);
}

async function browser(t) {
  const binary = [process.env.CDF_TEST_BROWSER,
    path.join(process.env.ProgramFiles || "", "Google/Chrome/Application/chrome.exe"),
    path.join(process.env["ProgramFiles(x86)"] || "", "Microsoft/Edge/Application/msedge.exe")].find((p) => p && fs.existsSync(p));
  assert.ok(binary, "Set CDF_TEST_BROWSER to a Chromium browser executable");
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "cdf-gui-ux-"));
  const child = spawn(binary, ["--headless=new", "--no-first-run", "--no-default-browser-check",
    "--disable-background-networking", "--disable-component-update", "--disable-extensions", "--disable-sync",
    "--no-proxy-server", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
    "--user-data-dir=" + profile, "about:blank"], {windowsHide:true, stdio:"ignore"});
  const exited = once(child, "exit");
  let ws;
  t.after(async () => {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({id: 0, method: "Browser.close"}));
      ws.close();
    }
    if (child.exitCode === null) {
      const timer = setTimeout(() => child.kill(), 4000);
      try { await exited; } finally { clearTimeout(timer); }
    }
    assert.equal(path.dirname(path.resolve(profile)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(profile).startsWith("cdf-gui-ux-"));
    fs.rmSync(profile, {recursive:true, force:true, maxRetries:6, retryDelay:150});
  });
  const marker = path.join(profile, "DevToolsActivePort");
  await until(() => fs.existsSync(marker) && fs.readFileSync(marker, "utf8").includes("\n"), "browser startup");
  const port = Number(fs.readFileSync(marker, "utf8").split("\n")[0]);
  const pages = await (await fetch("http://127.0.0.1:" + port + "/json/list")).json();
  ws = new WebSocket(pages.find((p) => p.type === "page").webSocketDebuggerUrl);
  await once(ws, "open");
  let sequence = 0;
  const calls = new Map();
  const exceptions = [];
  ws.addEventListener("message", (event) => {
    const msg = JSON.parse(event.data);
    if (msg.method === "Runtime.exceptionThrown") exceptions.push(msg.params.exceptionDetails.text);
    const call = calls.get(msg.id);
    if (!call) return;
    calls.delete(msg.id);
    if (msg.error) call.reject(Error(msg.error.message)); else call.resolve(msg.result);
  });
  const command = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    calls.set(id, {resolve, reject});
    ws.send(JSON.stringify({id, method, params}));
  });
  async function js(expression) {
    const result = await command("Runtime.evaluate", {expression, returnByValue:true, awaitPromise:true});
    if (result.exceptionDetails) throw Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  }
  await command("Runtime.enable");
  return {command, js, exceptions};
}

test("dashboard forms, history, release information and reflow", {timeout:90000}, async (t) => {
  const api = fixture();
  api.server.listen(0, "127.0.0.1");
  await once(api.server, "listening");
  t.after(() => { api.server.closeAllConnections(); api.server.close(); });
  const {js, command, exceptions} = await browser(t);
  api.status.origin = "http://127.0.0.1:" + api.server.address().port;
  const click = (selector) => js("document.querySelector(" + JSON.stringify(selector) + ").click()");
  const see = (expression) => until(() => js(expression), expression);
  const edit = (id, value) => js("(()=>{const e=document.getElementById(" + JSON.stringify(id) + ");e.value=" +
    JSON.stringify(value) + ";e.dispatchEvent(new Event('input',{bubbles:true}))})()");
  const size = (width) => command("Emulation.setDeviceMetricsOverride", {width, height:844, deviceScaleFactor:1, mobile:false});
  const select = (page) => click('.tab[data-page="' + page + '"]');
  await command("Page.navigate", {url:api.status.origin + "/#ticket=fixture"});
  await see("document.querySelector('#processes .pid-link') != null");

  await t.test("release mismatch and process evidence", async () => {
    assert.match(await js("$('gui-version').textContent"), /AAAAAAAAAAAA.*BBBBBBBBBBBB.*CCCCCCCCCCCC/);
    assert.match(await js("$('process-counts').textContent"), /已登记 2.*已加载 2.*传输就绪 1.*待重启 1/);
  });
  await t.test("all three switches use ordinary semicircular ends", async () => {
    const switches = await js(`['project-switch','proxy-switch','webrtc-switch'].map(id => {
      const s = getComputedStyle($(id)), thumb = getComputedStyle($(id).firstElementChild);
      return [s.width, s.height, s.borderTopLeftRadius, s.borderBottomRightRadius, s.cornerTopLeftShape, thumb.width, thumb.height];
    })`);
    for (const [width,height,r1,r2,shape,tw,th] of switches) {
      assert.deepEqual([width,height,r1,r2,tw,th], ["46px","26px","999px","999px","18px","18px"]);
      if (shape) assert.ok(["round", "superellipse(1)"].includes(shape), shape);
    }
  });
  await t.test("narrow layout, keyboard details and exact PID", async () => {
    for (const width of [1280, 768, 390, 320]) {
      await size(width);
      for (const page of ["overview", "settings", "connections"]) {
        await select(page);
        if (page === "connections") await see("$('connection-rows').rows.length===3");
        assert.ok(await js("document.documentElement.scrollWidth<=innerWidth"), page + " overflows at " + width);
        const report = process.env.CDF_GUI_SCREENSHOT_DIR;
        if (report && ((width === 1280 && ["overview","settings"].includes(page)) || (width === 390 && page === "connections"))) {
          if (page === "settings") {
            await see("$('profile-caption').textContent==='日常代理'");
            await js("$('proxy-form').closest('article').scrollIntoView({block:'center',behavior:'instant'})");
          }
          const shot = await command("Page.captureScreenshot", {format:"png", captureBeyondViewport:false});
          fs.mkdirSync(report, {recursive:true});
          fs.writeFileSync(path.join(report, page + "-" + width + ".png"), Buffer.from(shot.data, "base64"));
          if (page === "overview") {
            const clip = await js(`(() => {
              const a = $('project-switch').closest('.card').getBoundingClientRect();
              const b = $('proxy-switch').closest('.card').getBoundingClientRect();
              return {x:a.left+scrollX-5, y:a.top+scrollY-5, width:b.right-a.left+10, height:a.height+10, scale:1};
            })()`);
            const cards = await command("Page.captureScreenshot", {format:"png", clip, captureBeyondViewport:true});
            fs.writeFileSync(path.join(report,"overview-switches.png"),Buffer.from(cards.data,"base64"));
          }
          await js("window.scrollTo({top:0,behavior:'instant'})");
        }
      }
    }
    await select("overview");
    await click("#processes summary");
    await js("document.querySelector('#processes summary').focus()");
    await js("refresh()");
    assert.ok(await js("document.querySelector('#processes details').open && document.activeElement.matches('summary')"));
    await click('#processes button[data-pid="42"]');
    await see("$('filter').value==='pid:42' && $('connection-rows').rows.length===1");
    assert.match(await js("$('connection-counts').textContent"), /匹配 1 .*共 3/);
  });
  await t.test("connection totals, filter and clear scope", async () => {
    await edit("filter", "");
    assert.equal(await js("$('active-count').textContent"), "3");
    assert.match(await js("$('connection-counts').textContent"), /转发中 0.*建立中 2.*采集暂离 1/);
    assert.ok(await js("$('clear').hidden"));
    await click("#show-closed"); await edit("filter", "pid:42");
    assert.match(await js("$('connection-counts').textContent"), /匹配 1 .*共 2/);
    assert.match(await js("$('clear').textContent"), /清除全部 2 条已关闭/);
    await click("#clear"); await see("$('closed-count').textContent==='0'");
    assert.equal(api.history.active.length, 3); assert.equal(api.history.dns.length, 1);
    await click("#show-dns");
    assert.match(await js("$('clear').textContent"), /清除全部 1 条 DNS/);
    await click("#clear"); await see("$('dns-count').textContent==='0'");
    assert.equal(api.history.active.length, 3);
  });
  await select("settings");
  await t.test("external browser consent defaults off and reports deployment separately", async () => {
    const toggle = "$('browser-consent-switch')";
    assert.equal(await js(toggle+".getAttribute('aria-checked')"), "false");
    await click("#browser-consent-switch");
    await see(toggle+".getAttribute('aria-checked')==='true' && !"+toggle+".disabled");
    assert.match(await js("$('browser-consent-note').textContent"), /需要部署/);
    api.data.browserConsentProviderCurrent=true;
    await js("refresh()");
    assert.match(await js("$('browser-consent-note').textContent"), /已加载本版/);
    await click("#browser-consent-switch");
    await see(toggle+".getAttribute('aria-checked')==='false'");
    assert.equal(api.submissions.length,0);
  });
  await t.test("adapter list contains only real adapters and missing selections require a replacement", async () => {
    assert.equal(await js("$('adapter').value"), wired);
    assert.ok(await js("$('save-proxy').disabled && $('test-proxy').disabled"));
    api.data.adapters.shift(); await js("refresh()");
    assert.equal(await js("$('adapter').selectedIndex"), -1);
    assert.deepEqual(await js("Array.from($('adapter').options,o=>o.value)"), [wifi]);
    assert.match(await js("$('adapter-note').textContent"), /未找到.*0001/);
    assert.ok(await js("$('save-proxy').disabled && $('test-proxy').disabled"));
    api.data.adapters.unshift({guid:wired, name:"Ethernet", up:false}); await js("refresh()");
    await edit("adapter", wifi);
    assert.match(await js("$('adapter-note').textContent"), /Ethernet → Wi-Fi/);
    assert.ok(await js("!$('save-proxy').disabled"));
  });
  await t.test("save acknowledgement preserves newer input across a stale status poll", async () => {
    await edit("offset", "60");
    await js("$('save-time').scrollIntoView({block:'center'})"); await click("#save-time");
    await until(() => api.job?.state === "running", "save submitted");
    api.job.phase = "authorization";
    await see("$('time-feedback').textContent.includes('等待管理员授权')");
    assert.ok(await js("(()=>{const r=$('time-feedback').getBoundingClientRect();return r.top<innerHeight&&r.bottom>0})()"));
    await edit("offset", "120");
    api.status.statusVersion++;
    Object.assign(api.job, {state:"done", statusVersion:1, result:{timeRevision:rev(4), message:"已保存"}});
    await see("$('time-feedback').textContent.includes('60 秒')");
    assert.equal(await js("$('offset').value"), "120");
    assert.ok(await js("$('save-time').disabled && !$('time-draft').hidden"));
    api.data.config.time.utcOffsetSeconds=60; api.data.timeRevision=rev(4); api.status.snapshotVersion=1;
    await see("!$('save-time').disabled");
    await click("#save-time"); await until(() => api.submissions.length===2, "next save");
    assert.equal(api.submissions[1].revision, rev(4)); assert.equal(api.submissions[1].time.utcOffsetSeconds,120);
    api.job.state="failed"; api.job.statusVersion=1; api.job.message="样例冲突";
    await see("$('time-feedback').textContent.includes('样例冲突')");
    api.data.timeRevision=rev(5); api.data.config.time.utcOffsetSeconds=35; await js("refresh()");
    assert.equal(await js("$('offset').value"),"120");
    assert.ok(await js("$('save-time').disabled"));
    await click("#time-reload"); assert.equal(await js("$('offset').value"),"35");
  });
  await t.test("a later named selection survives the in-flight apply and stale status", async () => {
    await click("#save-proxy"); await until(() => api.submissions.length===3, "proxy save");
    assert.equal(api.submissions[2].proxy.interfaceGuid,wifi);
    assert.equal(api.submissions[2].profileId, "a1");
    assert.deepEqual(Object.keys(api.submissions[2].proxy), ["interfaceGuid"]);
    await edit("proxy-profile","b2");
    api.status.statusVersion=2;
    Object.assign(api.job,{state:"done",statusVersion:2,result:{proxyRevision:rev(6),message:"已保存"}});
    await see("$('proxy-feedback').textContent.includes('草稿')");
    api.status.snapshotVersion=2; api.data.proxyRevision=rev(6); api.data.proxy.interfaceGuid=wifi;
    await js("refresh()");
    assert.equal(await js("$('profile-caption').textContent"),"Travel");
    await click("#proxy-reload");
    assert.equal(await js("$('profile-caption').textContent"),"日常代理");
  });
  await t.test("a clean save stays visible while the full snapshot is catching up", async () => {
    await edit("offset","7200"); await click("#save-time");
    await until(() => api.submissions.length===4, "clean save");
    api.status.statusVersion=3;
    Object.assign(api.job,{state:"done",statusVersion:3,result:{timeRevision:rev(7),message:"本次保存完成"}});
    await see("$('time-feedback').textContent.includes('本次保存完成')");
    await js("refresh()");
    assert.equal(await js("$('offset').value"),"7200");
    assert.ok(await js("$('save-time').disabled && $('time-draft').hidden"));
    api.status.snapshotVersion=3; api.data.timeRevision=rev(7); api.data.config.time.utcOffsetSeconds=7200;
    await see("!$('save-time').disabled");
  });
  await t.test("picker shows names when closed, names and IPs in the menu, and keeps actions outside", async () => {
    assert.deepEqual(await js("Array.from($('proxy-profile').options,o=>o.textContent)"), ["日常代理 · 192.0.2.2","Travel · 192.0.2.8"]);
    assert.equal(await js("$('profile-caption').textContent"),"日常代理");
    assert.equal(await js("getComputedStyle($('proxy-profile')).color"),"rgba(0, 0, 0, 0)");
    assert.notEqual(await js("getComputedStyle($('proxy-profile').options[0]).color"), "rgba(0, 0, 0, 0)");
    await js("$('proxy-profile').focus()");
    for (const type of ["keyDown","keyUp"]) await command("Input.dispatchKeyEvent", {type,key:"ArrowDown",code:"ArrowDown",windowsVirtualKeyCode:40});
    await see("$('profile-caption').textContent==='Travel'");
    await click("#profile-rename");
    await edit("profile-name","日常代理"); await click("#profile-store");
    await see("$('catalog-feedback').textContent.includes('已存在')");
    assert.ok(await js("!$('profile-editor').hidden && $('profile-name').value==='日常代理'"));
    await edit("profile-name","TRAVEL"); await click("#profile-store");
    await see("$('profile-caption').textContent==='TRAVEL' && $('profile-editor').hidden");
    assert.equal(api.catalogWrites.at(-1).path,"/api/profiles/rename");
    await click("#profile-new");
    const fields = {"profile-name":"晚间代理","proxy-server":"192.0.2.16","proxy-port":"443","proxy-sni":"test.example",
      "proxy-uuid":"11111111-2222-4333-8444-555555555555","proxy-key":"A".repeat(43),"proxy-short-id":"00ab"};
    for (const [id,val] of Object.entries(fields)) await edit(id,val);
    await js("refresh()");
    assert.equal(await js("$('proxy-uuid').value"),fields["proxy-uuid"]);
    await click("#profile-store");
    await see("$('profile-caption').textContent==='晚间代理' && $('profile-editor').hidden");
    assert.equal(await js("$('proxy-uuid').value"),"");
    assert.match(await js("$('proxy-profile').selectedOptions[0].textContent"), /192\.0\.2\.16/);
    const yaml = "proxies:\n  - {name: 其他协议, type: ss}\n  - {name: YAML 示例, type: vless, server: 192.0.2.7, port: 443, " +
      "uuid: " + fields["proxy-uuid"] + ", servername: edge.example, flow: xtls-rprx-vision, reality-opts: {public-key: " +
      fields["proxy-key"] + ", short-id: '00ab'}}\n";
    await js(`(() => {const bag=new DataTransfer();bag.items.add(new File([${JSON.stringify(yaml)}],"example.yml",{type:"application/yaml"}));
      const input=$('profile-file');input.files=bag.files;input.dispatchEvent(new Event('change',{bubbles:true}));})()`);
    await see("$('profile-caption').textContent==='YAML 示例'");
    assert.match(await js("$('catalog-feedback').textContent"), /导入 1 项.*跳过 1/);
    assert.match(api.catalogWrites.at(-1).type,/application\/yaml/);
    assert.equal(api.catalogWrites.at(-1).body,yaml);
    assert.equal(api.submissions.length,4,"editing the catalog must not apply a proxy");
    api.catalog.profiles = []; api.catalog.activeId = "";
    api.data.adapters = []; await js("refresh()"); await js("refreshProfiles(true)");
    await see("$('proxy-profile').options.length===0 && $('adapter').options.length===0");
    assert.ok(await js("$('proxy-profile').disabled && $('adapter').disabled && $('save-proxy').disabled && !$('profile-import').disabled"));
  });
  assert.deepEqual(exceptions, []);
});

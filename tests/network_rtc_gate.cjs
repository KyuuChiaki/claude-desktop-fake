'use strict';

const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'network_rtc_policy.js'), 'utf8');

async function applyWebRTCPolicy(contents, disabled = true, onError = () => {}) {
  contents.setWebRTCIPHandlingPolicy('disable_non_proxied_udp');
  if (!disabled) return;

  const debug = contents.debugger;
  debug.attach('1.3');
  const attach = {autoAttach: true, waitForDebuggerOnStart: true, flatten: true};
  const script = {source, runImmediately: true};
  const prepare = async (id) => {
    await debug.sendCommand('Page.enable', {}, id);
    await debug.sendCommand('Page.addScriptToEvaluateOnNewDocument', script, id);
    await debug.sendCommand('Target.setAutoAttach', attach, id);
  };
  debug.on('detach', (_event, reason) => {
    if (reason !== 'target_closed') onError(new Error('WebRTC policy detached'));
  });
  debug.on('message', async (_event, method, params) => {
    if (method !== 'Target.attachedToTarget') return;
    try {
      if (['iframe', 'page'].includes(params.targetInfo.type)) await prepare(params.sessionId);
    } catch (error) {
      onError(error);
    } finally {
      await debug.sendCommand('Runtime.runIfWaitingForDebugger', {}, params.sessionId).catch(() => {});
    }
  });
  await prepare();
}

module.exports = {applyWebRTCPolicy};

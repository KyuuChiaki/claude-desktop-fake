'use strict';

const {app, BrowserWindow} = require('electron');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {applyWebRTCPolicy} = require('./network_rtc_gate.cjs');

const directory = process.env.CDF_WEBRTC_TEST_DIRECTORY;
app.setPath('userData', path.join(directory, 'userdata'));
app.enableSandbox();
app.on('window-all-closed', () => {});

async function sample(mode, preference) {
  const browser = new BrowserWindow({show: false, webPreferences: {
    sandbox: true, contextIsolation: true, nodeIntegration: false,
  }});
  const setupErrors = [];
  try {
    const contents = browser.webContents;
    const protection = applyWebRTCPolicy(contents, preference, error => setupErrors.push(String(error)));
    await browser.loadURL('about:blank');
    await protection;
    await browser.loadURL('data:text/html,<title>WebRTC policy probe</title>');
    const result = await contents.executeJavaScript(`(async () => {
      function attempt(realm, urls) {
        let connection;
        try {
          connection = new realm.RTCPeerConnection({iceServers:urls.map(url => ({
            urls:url, username:'fixture', credential:'fixture',
          }))});
          return 'created';
        } catch (error) {
          return error.name;
        } finally {
          connection?.close();
        }
      }
      // Constructing with these URLs exercises the session gate without
      // starting ICE gathering or contacting a remote TURN server.
      const tcp = attempt(window, ['turn:203.0.113.10:3478?transport=tcp']);
      const tls = attempt(window, ['turns:203.0.113.10:5349?transport=tcp']);
      const frame = document.createElement('iframe');
      const loaded = new Promise(resolve => frame.onload = resolve);
      frame.srcdoc = '<p>fixture</p>';
      document.body.appendChild(frame);
      await loaded;
      const subframe = attempt(frame.contentWindow, []);
      const ordinaryFetch = await (await fetch('data:text/plain,available')).text();
      return {tcp,tls,subframe,ordinaryFetch};
    })()`);
    const expected = preference === false ? 'created' : 'NotSupportedError';
    assert.equal(result.tcp, expected, mode + ' TURN/TCP');
    assert.equal(result.tls, expected, mode + ' TURN/TLS');
    assert.equal(result.subframe, expected, mode + ' iframe');
    assert.equal(result.ordinaryFetch, 'available');
    assert.equal(contents.getWebRTCIPHandlingPolicy(), 'disable_non_proxied_udp');
    assert.deepEqual(setupErrors, []);
    return {mode, ...result};
  } finally {
    browser.destroy();
  }
}

app.whenReady().then(async () => {
  const results = [
    await sample('default'),
    await sample('enabled', true),
    await sample('disabled', false),
  ];
  fs.writeFileSync(path.join(directory, 'report.json'), JSON.stringify({passed: true, results}, null, 2));
  app.exit(0);
}).catch(error => {
  fs.writeFileSync(path.join(directory, 'report.json'), JSON.stringify({passed: false, error: String(error.stack)}, null, 2));
  app.exit(1);
});

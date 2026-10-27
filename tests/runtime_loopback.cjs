'use strict';

// The Windows ephemeral range can contain Chromium's restricted ports (e.g.
// 5060). Use high unprivileged ports without changing browser security flags.
// https://github.com/chromium/chromium/blob/main/net/base/port_util.cc
module.exports = async function listenLoopback(server) {
  for (let attempt = 0; attempt < 128; ++attempt) {
    const port = 49152 + Math.floor(Math.random() * 16384);
    try {
      await new Promise((resolve, reject) => {
        const cleanup = () => {
          server.removeListener('listening', listening);
          server.removeListener('error', failed);
        };
        const listening = () => { cleanup(); resolve(); };
        const failed = error => { cleanup(); reject(error); };
        server.once('listening', listening);
        server.once('error', failed);
        try { server.listen(port, '127.0.0.1'); } catch (error) { failed(error); }
      });
      return server.address().port;
    } catch (error) {
      if (!['EADDRINUSE', 'EACCES', 'EPERM'].includes(error.code)) throw error;
    }
  }
  throw new Error('No available high loopback port after 128 bounded attempts');
};

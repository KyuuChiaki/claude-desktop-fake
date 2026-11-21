'use strict';
const {app,BrowserWindow,session,utilityProcess}=require('electron');
const {Worker}=require('node:worker_threads');
const fs=require('node:fs');const path=require('node:path');
// Account for the authenticated proxy's extra RTT; cancellation is tested
// independently at the Windows API level rather than hidden by synchronous I/O.
require('node:net').setDefaultAutoSelectFamilyAttemptTimeout(5000);
const output=process.env.CDF_NETWORK_REPORT;
app.setPath('userData',process.env.CDF_NETWORK_USER_DATA);
app.enableSandbox();
const addon=require(process.env.CDF_NETWORK_ADDON);
const report={schemaVersion:1,passed:false,pid:process.pid,version:process.versions,contexts:{},frames:[],processes:[]};
report.networkOptions={autoSelectFamilyAttemptTimeout:5000};
function checkpoint(stage){report.stage=stage;fs.writeFileSync(output+'.progress.json',JSON.stringify({...report,processes:app.getAppMetrics().map(p=>({pid:p.pid,type:p.type}))},null,2));}
const {applyWebRTCPolicy}=require('./network_rtc_gate.cjs');
const inspectRtc=()=>{
  const result={available:typeof RTCPeerConnection==='function',blocked:false,error:null};
  try{const pc=new RTCPeerConnection();pc.close();}catch(error){result.blocked=error.name==='NotSupportedError';result.error=error.name;}
  return result;
};
async function nodeRequest(){const response=await fetch('https://cleanip.io/who-am-i');const body=await response.arrayBuffer();return{passed:response.ok,status:response.status,bytes:body.byteLength,provider:addon.sample()};}
async function workerRequest(){return await new Promise((resolve,reject)=>{
  const worker=new Worker(`require('node:net').setDefaultAutoSelectFamilyAttemptTimeout(5000);const {parentPort}=require('node:worker_threads'); const addon=require(process.env.CDF_NETWORK_ADDON); (async()=>{try{const r=await fetch('https://cleanip.io/who-am-i'); const b=await r.arrayBuffer(); parentPort.postMessage({passed:r.ok,status:r.status,bytes:b.byteLength,provider:addon.sample()});}catch(e){parentPort.postMessage({passed:false,error:String(e),provider:addon.sample()});}})();`,{eval:true});
  worker.once('message',resolve);worker.once('error',reject);
});}
async function utilityRequest(){return await new Promise((resolve,reject)=>{const child=utilityProcess.fork(path.join(__dirname,'network_child.cjs'));child.once('message',resolve);child.once('exit',code=>{if(code)reject(new Error('utility exit '+code));});});}
async function main(){
  report.contexts.early=addon.sample();
  await app.whenReady();
  await session.defaultSession.netLog.startLogging(output+'.netlog.json',{captureMode:'default'});
  session.defaultSession.setPermissionRequestHandler((_contents,_permission,callback)=>callback(false));
  const window=new BrowserWindow({show:false,webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false}});
  const protection=applyWebRTCPolicy(window.webContents,true,error=>{report.rtcPolicyError=String(error);});
  await window.loadURL('about:blank');await protection;
  await window.loadFile(path.join(__dirname,'network_page.html'));
  for(const frame of window.webContents.mainFrame.framesInSubtree){report.frames.push({url:frame.url,result:await frame.executeJavaScript('('+inspectRtc.toString()+')()')});}
  report.contexts.freshFrame=await window.webContents.executeJavaScript(`(()=>{const f=document.createElement('iframe');document.body.append(f);let result;try{const p=new f.contentWindow.RTCPeerConnection();p.close();result={blocked:false};}catch(e){result={blocked:e.name==='NotSupportedError',error:e.name};}f.remove();return result;})()`);
  checkpoint('node');report.contexts.node=await nodeRequest();
  checkpoint('worker');report.contexts.worker=await workerRequest();
  checkpoint('utility');report.contexts.utility=await utilityRequest();
  checkpoint('renderer-navigation');await window.loadURL('https://cleanip.io/who-am-i');
  report.contexts.renderer=await window.webContents.executeJavaScript(`(async()=>{const r=await fetch(location.href,{cache:'no-store'});return {passed:r.ok,status:r.status,rtc:(${inspectRtc.toString()})(),title:document.title};})()`);
  report.contexts.webWorker=await window.webContents.executeJavaScript(`new Promise((resolve,reject)=>{const source="onmessage=async()=>{try{const r=await fetch('https://cleanip.io/who-am-i');postMessage({passed:r.ok,status:r.status,rtcAvailable:typeof RTCPeerConnection==='function'});}catch(e){postMessage({passed:false,error:String(e)});}}";const u=URL.createObjectURL(new Blob([source],{type:'text/javascript'}));const w=new Worker(u);w.onmessage=e=>{w.terminate();URL.revokeObjectURL(u);resolve(e.data);};w.onerror=e=>reject(new Error(e.message));w.postMessage(0);})`);
  report.processes=app.getAppMetrics().map(p=>({pid:p.pid,type:p.type,serviceName:p.serviceName||null}));
  report.contexts.final=addon.sample();
  await session.defaultSession.netLog.stopLogging();
  report.passed=(report.contexts.early.state&15)===15&&['node','worker','utility','renderer','webWorker'].every(k=>report.contexts[k].passed)&&report.frames.every(f=>f.result.blocked)&&report.contexts.freshFrame.blocked&&report.contexts.renderer.rtc.blocked;
  // Give the controller a bounded window for read-only diagnostics of child processes.
  fs.writeFileSync(output,JSON.stringify(report,null,2));
  await new Promise(resolve=>setTimeout(resolve,3000));window.destroy();app.exit(report.passed?0:1);
}
main().catch(async error=>{report.error=String(error.stack||error);report.cause=String(error.cause?.stack||error.cause||'');report.processes=app.getAppMetrics().map(p=>({pid:p.pid,type:p.type}));fs.writeFileSync(output,JSON.stringify(report,null,2));await new Promise(resolve=>setTimeout(resolve,7000));app.exit(1);});

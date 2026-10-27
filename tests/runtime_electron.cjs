'use strict';
const {app,BrowserWindow,utilityProcess,net,session}=require('electron');
const fs=require('node:fs'),path=require('node:path'),http=require('node:http');
const {Worker}=require('node:worker_threads');
const sample=require('./runtime_sample.cjs');
const listenLoopback=require('./runtime_loopback.cjs');
const output=process.env.CDF_RUNTIME_REPORT;
if(!output || !process.env.CDF_RUNTIME_USER_DATA) throw new Error('An isolated report and user-data directory are required');
app.setPath('userData',process.env.CDF_RUNTIME_USER_DATA);
const report={scope:'official Electron matching-version isolated fixture; not Claude application acceptance',beforeReady:sample()};
let server,window;
async function run(){
  if(process.env.CDF_RUNTIME_TEST_HANG==='1')await new Promise(()=>{});
  await app.whenReady();
  report.main=sample();report.electron={locale:app.getLocale(),systemLocale:app.getSystemLocale(),preferredSystemLanguages:app.getPreferredSystemLanguages()};
  if(process.env.CDF_RUNTIME_NATIVE)report.native=JSON.parse(require(process.env.CDF_RUNTIME_NATIVE).sample());
  const start=sample();await new Promise(r=>setTimeout(r,180));report.elapsed={start,end:sample()};
  report.nodeWorker=await new Promise((resolve,reject)=>{const w=new Worker(path.join(__dirname,'runtime_child.cjs'));w.once('message',resolve);w.once('error',reject);});
  report.nodeUtility=await new Promise((resolve,reject)=>{const child=utilityProcess.fork(path.join(__dirname,'runtime_child.cjs'),[],{stdio:'ignore'});const timer=setTimeout(()=>{child.kill();reject(new Error('utility timeout'));},10000);child.once('message',x=>{clearTimeout(timer);resolve(x);});child.once('exit',code=>{if(code)reject(new Error('utility exit '+code));});});
  server=http.createServer((req,res)=>{if(req.url==='/redirect'){res.writeHead(302,{Location:'/'});res.end();return;}res.setHeader('Content-Type','application/json');res.setHeader('Access-Control-Allow-Origin','*');res.end(JSON.stringify({acceptLanguage:req.headers['accept-language']||null}));});
  report.loopbackPort=await listenLoopback(server);const url=`http://127.0.0.1:${report.loopbackPort}/`;
  window=new BrowserWindow({show:false,webPreferences:{sandbox:true,nodeIntegration:false,contextIsolation:true}});
  await window.loadURL(url);
  report.renderer=await window.webContents.executeJavaScript(`(${sample.toString()})()`);
  report.webWorker=await window.webContents.executeJavaScript(`new Promise((resolve,reject)=>{const u=URL.createObjectURL(new Blob([${JSON.stringify('postMessage(('+sample.toString()+')())')}],{type:'text/javascript'}));const w=new Worker(u);w.onmessage=e=>{w.terminate();URL.revokeObjectURL(u);resolve(e.data)};w.onerror=e=>reject(new Error(e.message));})`);
  report.networkDefault=await window.webContents.executeJavaScript(`fetch(${JSON.stringify(url)}).then(r=>r.json())`);
  report.networkElectron=await net.fetch(url).then(r=>r.json());
  const partition=session.fromPartition('cdf-runtime-isolated');report.networkPartition=await partition.fetch(url).then(r=>r.json());
  partition.setUserAgent(window.webContents.getUserAgent(),'fr-CA,fr');report.networkPartitionExplicit=await partition.fetch(url).then(r=>r.json());
  report.networkHeader=await net.fetch(url,{headers:{'Accept-Language':'ko-KR'}}).then(r=>r.json());
  report.networkRedirect=await net.fetch(url+'redirect',{headers:{'Accept-Language':'ko-KR'}}).then(r=>r.json());
  report.nodeFetch=await fetch(url).then(r=>r.json());
  report.nodeHttp=await new Promise((resolve,reject)=>{http.get(url,r=>{let text='';r.on('data',x=>text+=x);r.on('end',()=>resolve(JSON.parse(text)))}).on('error',reject)});
  window.webContents.session.setUserAgent(window.webContents.getUserAgent(),'ko-KR');
  report.networkExplicit=await window.webContents.executeJavaScript(`fetch(${JSON.stringify(url)}).then(r=>r.json())`);
  if(process.env.CDF_RUNTIME_TEST_TZ==='1'){
    process.env.TZ='Asia/Tokyo';report.mainExplicitTZ=sample();delete process.env.TZ;report.mainClearedTZ=sample();
  }
  report.end=sample();
}
run().then(()=>finish()).catch(e=>{report.error={message:e.message,stack:e.stack};finish(1);});
function finish(code=0){fs.writeFileSync(output,JSON.stringify(report,null,2));const exit=()=>{if(window)window.destroy();if(server)server.close();app.exit(code)};if(process.env.CDF_RUNTIME_HOLD==='1')setTimeout(exit,12000);else exit();}
setTimeout(()=>{report.error={message:'fixture timeout'};finish(2);},45000).unref();

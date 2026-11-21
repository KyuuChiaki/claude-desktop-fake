'use strict';
const fs=require('node:fs');
const path=require('node:path');
const directory=process.env.CDF_BROWSER_SESSION;
function stage(name){fs.writeFileSync(path.join(directory,'startup-stage.json'),JSON.stringify({phase:name,pid:process.pid,time:new Date().toISOString()}));}
stage('script-entered');
const {app,BrowserWindow,WebContentsView,Menu,ipcMain,session}=require('electron');
stage('electron-imported');
require('node:net').setDefaultAutoSelectFamilyAttemptTimeout(5000);
stage('net-imported');
const config=JSON.parse(fs.readFileSync(path.join(directory,'config.json'),'utf8'));
app.setPath('userData',path.join(directory,'userdata'));
app.enableSandbox();
const addon=require(config.addon);
stage('addon-imported');
const {applyWebRTCPolicy}=require('./network_rtc_gate.cjs');
const webRTCDisabled=config.webRTCDisabled!==false;
let win,view,closing=false,policyReady=false,exitIp=null,pageLoaded=false,lastError=null,httpStatus=null;
const initial=addon.sample();
function snapshot(){
  if(closing)return;
  let origin=null;try{origin=new URL(view?.webContents.getURL()).origin;}catch{}
  const data={version:1,pid:process.pid,visible:!!win&&!win.isDestroyed()&&win.isVisible(),
    interfaceAlias:config.interfaceAlias,initial,provider:addon.sample(),policyReady,webRTCDisabled,exitIp,
    pageLoaded,httpStatus,lastError,origin,processes:app.getAppMetrics().map(p=>({pid:p.pid,type:p.type,serviceName:p.serviceName||null})),
    updated:new Date().toISOString()};
  const output=path.join(directory,'browser.json');fs.writeFileSync(output+'.tmp',JSON.stringify(data,null,2));fs.renameSync(output+'.tmp',output);
}
function toolbar(message){if(win&&!win.isDestroyed())win.webContents.send('browser-state',{
  url:view?.webContents.getURL()||config.url,interfaceAlias:config.interfaceAlias,exitIp,
  status:message||lastError||(view?.webContents.isLoading()?'正在加载…':'就绪'),
  policyReady,webRTCDisabled,back:!!view?.webContents.navigationHistory.canGoBack(),forward:!!view?.webContents.navigationHistory.canGoForward()});}
function allowed(value){const url=new URL(value.includes('://')?value:'https://'+value);if(!['http:','https:'].includes(url.protocol)||url.username||url.password)throw new Error('请输入 HTTP/HTTPS 地址');return url.href;}
function navigate(value){
  let url;try{url=allowed(value);}catch(error){toolbar(error.message);return;}
  pageLoaded=false;lastError=null;httpStatus=null;
  view.webContents.loadURL(url).catch(error=>{lastError=error.code||'页面连接失败';toolbar();snapshot();});
}
function action(name){
  if(!view||view.webContents.isDestroyed())return;const history=view.webContents.navigationHistory;
  if(name==='back'&&history.canGoBack())history.goBack();
  else if(name==='forward'&&history.canGoForward())history.goForward();
  else if(name==='reload')view.webContents.reload();
  else if(name==='address'){win.webContents.focus();win.webContents.send('focus-address');}
  else if(name==='stop')view.webContents.stop();
}
function shortcuts(contents){contents.on('before-input-event',(event,input)=>{
  if(input.type!=='keyDown')return;const key=input.key.toLowerCase();let command;
  if(input.control&&key==='l')command='address';else if(input.control&&key==='r')command='reload';
  else if(input.alt&&key==='arrowleft')command='back';else if(input.alt&&key==='arrowright')command='forward';
  if(command){event.preventDefault();action(command);}
});}
async function main(){
  stage('main');
  if((initial.state&15)!==15||(initial.state&0x80000000))throw new Error('Network provider was not ready before application startup.');
  await app.whenReady();
  stage('app-ready');
  session.defaultSession.setPermissionRequestHandler((_web,_permission,callback)=>callback(false));
  session.defaultSession.setPermissionCheckHandler(()=>false);
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {label:'浏览',submenu:[{label:'地址栏',accelerator:'CmdOrCtrl+L',click:()=>action('address')},{label:'刷新',accelerator:'CmdOrCtrl+R',click:()=>action('reload')},{type:'separator'},{role:'quit',label:'关闭并撤销本次注册'}]},
    {label:'编辑',submenu:[{role:'undo'},{role:'redo'},{type:'separator'},{role:'cut'},{role:'copy'},{role:'paste'},{role:'selectAll'}]},
    {label:'显示',submenu:[{role:'resetZoom'},{role:'zoomIn'},{role:'zoomOut'},{role:'togglefullscreen'}]}
  ]));
  win=new BrowserWindow({width:1380,height:950,minWidth:900,minHeight:600,show:false,
    title:'CDF 网络测试浏览器 · 物理以太网',backgroundColor:'#f2f5f8',
    webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false,preload:path.join(__dirname,'network_browser_preload.cjs')}});
  stage('window-created');
  view=new WebContentsView({webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false,webSecurity:true}});
  win.contentView.addChildView(view);
  const layout=()=>{const [width,height]=win.getContentSize();view.setBounds({x:0,y:96,width,height:Math.max(0,height-96)});};
  win.on('resize',layout);layout();
  win.webContents.on('will-navigate',event=>event.preventDefault());
  view.webContents.on('will-navigate',(event,url)=>{try{allowed(event.url||url);}catch{event.preventDefault();}});
  view.webContents.setWindowOpenHandler(details=>{navigate(details.url);return{action:'deny'};});
  stage('protecting');const protection=applyWebRTCPolicy(view.webContents,webRTCDisabled,()=>{
    if(!closing){lastError='WebRTC 保护初始化失败或已断开';win?.close();}
  });
  await view.webContents.loadURL('about:blank');await protection;
  policyReady=true;stage('protected');
  for(const contents of [win.webContents,view.webContents])shortcuts(contents);
  ipcMain.on('browser-navigate',(event,url)=>{if(event.sender===win.webContents&&event.senderFrame===win.webContents.mainFrame&&typeof url==='string')navigate(url);});
  ipcMain.on('browser-action',(event,name)=>{if(event.sender===win.webContents&&event.senderFrame===win.webContents.mainFrame)action(name);});
  view.webContents.on('did-start-loading',()=>toolbar());
  view.webContents.on('did-navigate',()=>toolbar());
  view.webContents.on('did-navigate-in-page',()=>toolbar());
  view.webContents.on('did-stop-loading',()=>{toolbar();snapshot();});
  view.webContents.on('did-finish-load',()=>{pageLoaded=true;lastError=null;toolbar();snapshot();});
  view.webContents.on('did-fail-load',(_event,code,description,_url,isMainFrame)=>{if(isMainFrame&&code!==-3){lastError=description;toolbar();snapshot();}});
  session.defaultSession.webRequest.onCompleted(details=>{if(details.webContentsId===view.webContents.id&&details.resourceType==='mainFrame'){httpStatus=details.statusCode;snapshot();}});
  win.on('closed',()=>{closing=true;if(view&&!view.webContents.isDestroyed())view.webContents.close();app.quit();});
  stage('toolbar-loading');await win.loadFile(path.join(__dirname,'network_browser.html'));stage('toolbar-loaded');win.show();win.focus();toolbar();snapshot();
  navigate(config.url);
  setInterval(snapshot,1000).unref();
  // A bounded, independent egress sample; only its IP field is retained.
  fetch('https://api.ipify.org?format=json',{signal:AbortSignal.timeout(15000)})
    .then(response=>{if(!response.ok)throw new Error('IP query failed');return response.json();})
    .then(value=>{exitIp=value.ip;toolbar();snapshot();}).catch(()=>{toolbar('出口 IP 查询暂未完成；可在地址栏手动测试');});
}
app.on('window-all-closed',()=>app.quit());
main().catch(error=>{fs.writeFileSync(path.join(directory,'startup-error.txt'),String(error.stack||error));app.exit(1);});

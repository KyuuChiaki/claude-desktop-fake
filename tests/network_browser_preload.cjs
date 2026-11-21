'use strict';
const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('cdfBrowser',{
  navigate:url=>ipcRenderer.send('browser-navigate',url),
  action:name=>ipcRenderer.send('browser-action',name),
  onState:callback=>ipcRenderer.on('browser-state',(_event,state)=>callback(state)),
  onFocus:callback=>ipcRenderer.on('focus-address',()=>callback())
});

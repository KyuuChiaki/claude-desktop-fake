'use strict';
const address=document.getElementById('address');
document.getElementById('navigate').addEventListener('submit',event=>{event.preventDefault();window.cdfBrowser.navigate(address.value);});
for(const name of ['back','forward','reload'])document.getElementById(name).onclick=()=>window.cdfBrowser.action(name);
for(const button of document.querySelectorAll('[data-url]'))button.onclick=()=>window.cdfBrowser.navigate(button.dataset.url);
window.cdfBrowser.onFocus(()=>{address.focus();address.select();});
window.cdfBrowser.onState(state=>{
  if(document.activeElement!==address)address.value=state.url||'';
  document.getElementById('back').disabled=!state.back;document.getElementById('forward').disabled=!state.forward;
  const rtc=state.policyReady?(state.webRTCDisabled?'已禁用':'禁用策略已关闭'):'准备中';
  document.getElementById('mode').textContent=`物理网卡：${state.interfaceAlias} · 私人代理${state.exitIp?' · 出口 '+state.exitIp:''} · WebRTC ${rtc}`;
  document.getElementById('message').textContent=state.status;
});

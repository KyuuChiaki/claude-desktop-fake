'use strict';
require('node:net').setDefaultAutoSelectFamilyAttemptTimeout(5000);
const parentPort=process.parentPort;
const addon=require(process.env.CDF_NETWORK_ADDON);
(async()=>{
  try{
    const response=await fetch('https://cleanip.io/who-am-i');
    const bytes=await response.arrayBuffer();
    parentPort.postMessage({passed:response.ok,status:response.status,bytes:bytes.byteLength,provider:addon.sample()});
  }catch(error){parentPort.postMessage({passed:false,error:String(error),provider:addon.sample()});}
})();

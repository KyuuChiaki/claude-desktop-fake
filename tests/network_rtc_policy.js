(() => {
  'use strict';
  const blocked=function(){throw new DOMException('WebRTC is disabled by the isolated network fixture.','NotSupportedError');};
  Object.defineProperty(blocked,'cdfNetworkDisabled',{value:true});
  for(const name of ['RTCPeerConnection','webkitRTCPeerConnection']){
    const old=Object.getOwnPropertyDescriptor(globalThis,name);
    if(old&&!old.configurable&&old.value&&old.value.cdfNetworkDisabled===true)continue;
    Object.defineProperty(globalThis,name,{value:blocked,writable:false,configurable:false});
  }
})();

'use strict';
const sample=require('./runtime_sample.cjs');
const {isMainThread,parentPort}=require('node:worker_threads');
const report={initial:sample()};
if(process.env.CDF_RUNTIME_TEST_TZ==='1'){
  process.env.TZ='Asia/Tokyo';report.explicitTZ=sample();
  delete process.env.TZ;report.clearedTZ=sample();
}
if(!isMainThread) parentPort.postMessage(report);
else if(process.parentPort) process.parentPort.postMessage(report);
else console.log(JSON.stringify(report));

'use strict';
// Pure snapshot function, also evaluated in sandboxed renderer and Web Worker.
function runtimeSample() {
  const p = globalThis.performance;
  const instant = new Date();
  const fixed = ['2024-01-15T12:00:00Z','2024-07-15T12:00:00Z',
    '2024-03-10T09:59:59Z','2024-03-10T10:00:00Z',
    '2024-11-03T08:59:59Z','2024-11-03T09:00:00Z',
    '2006-03-20T12:00:00Z','2007-03-20T12:00:00Z','2024-02-29T12:00:00Z','2035-07-15T12:00:00Z'];
  const result = {now:Date.now(),newDate:instant.getTime(),iso:instant.toISOString(),
    dateString:instant.toString(),hours:instant.getHours(),offsetMinutes:instant.getTimezoneOffset(),
    intlDate:new Intl.DateTimeFormat().resolvedOptions(),intlNumber:new Intl.NumberFormat().resolvedOptions(),
    formatted:instant.toLocaleString(),numberFormatted:(123456.78).toLocaleString(),
    explicitTokyo:new Intl.DateTimeFormat('ja-JP',{timeZone:'Asia/Tokyo',dateStyle:'full',timeStyle:'long'}).format(instant),
    explicitGerman:new Intl.NumberFormat('de-DE').format(123456.78),
    fixed:fixed.map(text=>{const d=new Date(text);return {input:text,ms:d.getTime(),iso:d.toISOString(),offset:d.getTimezoneOffset(),hours:d.getHours(),text:d.toString()};}),
    explicitUTC:Date.UTC(2024,0,15,12,0,0),explicitParse:Date.parse('2024-01-15T21:00:00+09:00'),
    performance:p?{timeOrigin:p.timeOrigin,now:p.now(),absolute:p.timeOrigin+p.now()}:null};
  if(typeof process==='object' && process.versions){
    result.process={type:process.type||'node',versions:{...process.versions},TZ:process.env.TZ??null,
      uptime:process.uptime(),hrtime:process.hrtime.bigint().toString(),
      creationTime:typeof process.getCreationTime==='function'?process.getCreationTime():null};
  }
  if(typeof navigator==='object') result.navigator={language:navigator.language,languages:Array.from(navigator.languages),userAgent:navigator.userAgent};
  const kinds=['DateTimeFormat','NumberFormat','Collator','PluralRules','RelativeTimeFormat','ListFormat','DisplayNames','Segmenter'];
  const intl=(locale)=>Object.fromEntries(kinds.map(k=>[k,new Intl[k](locale,k==='DisplayNames'?{type:'region'}:undefined).resolvedOptions()]));
  result.intlAll=intl(undefined);
  result.explicitIntl={};
  for(const locale of ['en-US','de-DE','fr-FR','ja-JP','en-GB','zh-CN']){
    result.explicitIntl[locale]={all:intl(locale),number:(123456.78).toLocaleString(locale),currency:new Intl.NumberFormat(locale,{style:'currency',currency:'EUR',useGrouping:true}).format(12345.67),collation:'ä'.localeCompare('z',locale)};
  }
  result.explicitCurrency=new Intl.NumberFormat('ja-JP',{style:'currency',currency:'EUR',minimumFractionDigits:3,numberingSystem:'latn'}).format(12345.67);
  const stable=new Date('2024-02-29T12:34:56Z');
  const formatted=(locale)=>({date:stable.toLocaleDateString(locale),time:stable.toLocaleTimeString(locale),combined:stable.toLocaleString(locale),comparison:'ä'.localeCompare('z',locale)});
  result.defaultFormatting=formatted(undefined);result.explicitFormatting={};
  for(const locale of ['en-US','de-DE','fr-FR','ja-JP','en-GB','zh-CN'])result.explicitFormatting[locale]=formatted(locale);
  result.fixedOracles={};
  for(const zone of ['America/Los_Angeles','America/New_York','UTC','Asia/Calcutta'])result.fixedOracles[zone]=fixed.map(text=>{const d=new Date(text);const parts=new Intl.DateTimeFormat('en-US',{timeZone:zone,hour:'2-digit',hourCycle:'h23',timeZoneName:'shortOffset'}).formatToParts(d);return {hours:Number(parts.find(p=>p.type==='hour').value),offsetName:parts.find(p=>p.type==='timeZoneName').value};});
  return result;
}
if(typeof module==='object') module.exports=runtimeSample;

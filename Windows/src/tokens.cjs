'use strict';
// Token usage from Claude Code's local transcripts (<config>/projects/**/*.jsonl). Only each reply's usage block,
// timestamp and message identity are read; conversation text is never kept.
const fs=require('node:fs');const path=require('node:path');const os=require('node:os');
const WINDOW=371; // 53 weeks: a full year of grid columns plus the current week.
const fields=[['input','input_tokens'],['output','output_tokens'],['cacheWrite','cache_creation_input_tokens'],['cacheRead','cache_read_input_tokens']];
const zero=()=>({input:0,output:0,cacheWrite:0,cacheRead:0});
const total=c=>c.input+c.output+c.cacheWrite+c.cacheRead;
function projectsPath(env=process.env){return path.join(env.CLAUDE_CONFIG_DIR||path.join(os.homedir(),'.claude'),'projects');}
function dayKey(time){const d=new Date(time);return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;}
function entries(text,since=0){const result=[];for(const line of text.split('\n')){
 // Cheap substring filter first: most lines carry no usage block.
 if(line.length>2_000_000||!line.includes('"output_tokens"'))continue;let object;try{object=JSON.parse(line);}catch{continue;}
 const message=object?.message,usage=message?.usage,time=typeof object?.timestamp==='string'?Date.parse(object.timestamp):NaN;if(!usage||typeof usage!=='object'||!Number.isFinite(time)||time<since)continue;
 const counts=Object.fromEntries(fields.map(([key,field])=>[key,Number.isFinite(usage[field])?Math.trunc(usage[field]):0]));if(total(counts)<=0)continue;
 // Message id + request id identify one reply wherever it was copied (resumed or forked sessions).
 const key=typeof message.id==='string'?message.id+':'+(typeof object.requestId==='string'?object.requestId:''):typeof object.uuid==='string'?object.uuid:`${object.timestamp}:${total(counts)}`;
 result.push({key,time,counts});}return result;}
// The last `days` local days, oldest first, zero-filled, each reply counted once (streamed copies only ever grow).
function daily(list,days=WINDOW,now=Date.now()){const replies=new Map();for(const e of list){const seen=replies.get(e.key);replies.set(e.key,seen?{key:e.key,time:Math.min(seen.time,e.time),counts:Object.fromEntries(fields.map(([k])=>[k,Math.max(seen.counts[k],e.counts[k])]))}:e);}
 const byDay=new Map();for(const e of replies.values()){const key=dayKey(e.time),sum=byDay.get(key)??zero();for(const [k] of fields)sum[k]+=e.counts[k];byDay.set(key,sum);}
 const today=new Date(now);return Array.from({length:days},(_,i)=>{const day=dayKey(new Date(today.getFullYear(),today.getMonth(),today.getDate()-(days-1-i)));return {day,...(byDay.get(day)??zero())};});}
// Files are re-read only when their size or modification time changes.
function scanner(root=projectsPath()){let cache=new Map(),scanning=null;
 async function walk(dir,out){let list;try{list=await fs.promises.readdir(dir,{withFileTypes:true});}catch{return;}for(const item of list){if(item.name.startsWith('.'))continue;const file=path.join(dir,item.name);if(item.isDirectory())await walk(file,out);else if(item.isFile()&&item.name.endsWith('.jsonl'))out.push(file);}}
 async function scan(){const since=Date.now()-(WINDOW+1)*86400000,files=[],next=new Map();await walk(root,files);
  for(const file of files){let stat;try{stat=await fs.promises.stat(file);}catch{continue;}if(stat.mtimeMs<since)continue;const cached=cache.get(file);
   if(cached&&cached.size===stat.size&&cached.mtimeMs===stat.mtimeMs){next.set(file,cached);continue;}
   try{next.set(file,{size:stat.size,mtimeMs:stat.mtimeMs,entries:entries(await fs.promises.readFile(file,'utf8'),since)});}catch{continue;}
   // Yield between files so a large history never stalls the window and pets.
   await new Promise(r=>setImmediate(r));}
  cache=next;return daily([...next.values()].flatMap(x=>x.entries));}
 return {refresh(){scanning??=scan().finally(()=>{scanning=null;});return scanning;}};}
// A plausible year for previews: started a few months ago, weekday work, quiet weekends.
function preview(now=Date.now()){const today=new Date(now);return Array.from({length:WINDOW},(_,i)=>{const offset=WINDOW-1-i,date=new Date(today.getFullYear(),today.getMonth(),today.getDate()-offset),weekend=[0,6].includes(date.getDay()),scale=weekend?0.15:0.6+((offset*37)%50)/100,idle=offset>130&&offset%41!==0||offset>0&&(offset*7)%9===0,base=idle?0:offset===0?0.45:scale;return {day:dayKey(date),input:Math.trunc(42000*base),output:Math.trunc(160000*base),cacheWrite:Math.trunc(900000*base),cacheRead:Math.trunc(7800000*base)};});}
module.exports={WINDOW,projectsPath,dayKey,entries,daily,scanner,preview,total};

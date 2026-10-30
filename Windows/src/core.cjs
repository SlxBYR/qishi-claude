'use strict';
const crypto = require('node:crypto');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const now = () => Date.now() / 1000;
const hash = x => crypto.createHash('sha256').update(x).digest('hex');
const titles = { idle:'待命',thinking:'思考中',reading:'阅读文件',writing:'编写代码',running:'运行命令',searching:'查找资料',delegating:'协同工作',asking:'等你回应',compact:'整理上下文',happy:'本轮完成',error:'遇到问题',sleeping:'休息中' };
const events = ['SessionStart','UserPromptSubmit','PreToolUse','PostToolUse','PostToolUseFailure','PermissionRequest','Notification','SubagentStart','SubagentStop','PreCompact','PostCompact','Stop','StopFailure','SessionEnd'];
const busy = p => !['idle','sleeping','happy','error','asking'].includes(p);
const percent = x => typeof x === 'number' && Number.isFinite(x) ? Math.min(100,Math.max(0,x)) : null;
const empty = () => ({sessions:{},events:[]});
const defaults = () => ({email:'',registeredAt:null,intervalMinutes:5,monitoring:true,desktopCard:false,cardOnTop:false,notify:false,showPet:true,approvals:false,notifications:false,alwaysOnTop:true,petScale:1,positions:{}});
function toolPose(name = '') { const t=name.toLowerCase(); if (t.includes('askuserquestion') || t==='exitplanmode') return 'asking'; if (/web|fetch|search|browse/.test(t)) return 'searching'; if (/read|grep|glob|list|view/.test(t)) return 'reading'; if (/write|edit|patch|replace|create/.test(t)) return 'writing'; if (/^(agent|task)$|subagent/.test(t)) return 'delegating'; return 'running'; }
function session(input,time) { return {id:hash(input.session_id),cwd:'',model:'',pose:'idle',event:'',tool:'',updated:time,started:time,turn:crypto.randomUUID(),toolCount:0,activeTools:{},agents:[],quota:[],quotaUpdated:null,contextUsed:null,cost:null,closed:false}; }
function project(s) { return s.cwd ? s.cwd.split(/[\\/]/).filter(Boolean).at(-1) || s.cwd : 'Claude 会话'; }
function ingest(state,input,event,time=now()) {
 if (!events.includes(event) || typeof input.session_id!=='string' || !input.session_id || input.session_id.length>512) return state;
 const id=hash(input.session_id),s=state.sessions[id] ?? session(input,time),tool=typeof input.tool_name==='string'?input.tool_name.slice(0,128):'',toolID=String(input.tool_use_id ?? tool).slice(0,256);
 if(typeof input.cwd==='string') s.cwd=input.cwd.slice(0,4096); if(typeof input.model==='string') s.model=input.model.slice(0,128);
 s.updated=time;s.event=event;s.closed=false;
 switch(event) {
 case 'SessionStart':s.pose='idle';break;
 case 'UserPromptSubmit':s.pose='thinking';s.toolCount=0;s.activeTools={};s.agents=[];s.turn=crypto.randomUUID();break;
 case 'PreToolUse':s.activeTools[toolID]=tool;s.tool=tool;s.toolCount++;s.pose=toolPose(tool);break;
 case 'PermissionRequest':s.pose='asking';s.tool=tool;break;
 case 'PostToolUse':case 'PostToolUseFailure':delete s.activeTools[toolID];s.tool=Object.values(s.activeTools)[0]??'';s.pose=event==='PostToolUseFailure'?'error':s.tool?toolPose(s.tool):s.agents.length?'delegating':'thinking';break;
 case 'Notification':if(['permission_prompt','elicitation_dialog','idle_prompt'].includes(input.notification_type))s.pose='asking';break;
 case 'SubagentStart':if(typeof input.agent_id==='string'&&!s.agents.includes(input.agent_id))s.agents.push(input.agent_id.slice(0,256));s.pose='delegating';break;
 case 'SubagentStop':s.agents=s.agents.filter(x=>x!==input.agent_id);s.pose=s.agents.length?'delegating':Object.keys(s.activeTools).length?toolPose(s.tool):'thinking';break;
 case 'PreCompact':s.pose='compact';break;case 'PostCompact':s.pose='thinking';break;
 case 'Stop':case 'StopFailure':case 'SessionEnd':s.pose=event==='Stop'?'happy':event==='StopFailure'?'error':'idle';s.closed=event==='SessionEnd';s.activeTools={};s.agents=[];s.tool='';break;
 }
 state.sessions[id]=s;state.sessions=Object.fromEntries(Object.values(state.sessions).filter(x=>time-x.updated<86400).sort((a,b)=>b.updated-a.updated).slice(0,100).map(x=>[x.id,x]));
 state.events.push({id:crypto.randomUUID(),session:id,project:project(s),title:titles[s.pose],tool,time});state.events=state.events.slice(-150);return state;
}
function statusline(state,input,time=now()) {
 if(typeof input.session_id!=='string'||!input.session_id||input.session_id.length>512)return state;
 const id=hash(input.session_id),s=state.sessions[id]??session(input,time);
 if(input.model&&typeof input.model==='object')s.model=String(input.model.display_name??input.model.id??'').slice(0,128);
 if(typeof input.cwd==='string')s.cwd=input.cwd.slice(0,4096);
 s.contextUsed=percent(input.context_window?.used_percentage);
 if(typeof input.cost?.total_cost_usd==='number'&&Number.isFinite(input.cost.total_cost_usd)&&input.cost.total_cost_usd>=0)s.cost=input.cost.total_cost_usd;
 s.quota=['five_hour','seven_day','spend_limit'].flatMap(id=>{const q=input.rate_limits?.[id],used=percent(q?.used_percentage);return used===null?[]:[{id,used,resetsAt:typeof q.resets_at==='number'?q.resets_at:null}];});
 s.quotaUpdated=input.rate_limits?time:null;state.sessions[id]=s;return state;
}
function liveSessions(state,time=now()){return Object.values(state.sessions).filter(s=>!s.closed&&time-s.updated<3600&&!((busy(s.pose)||s.pose==='asking')&&time-s.updated>300)).sort((a,b)=>b.updated-a.updated);}
function currentPose(state,requests=[],time=now()){const live=liveSessions(state,time);if(requests.length||live.some(s=>s.pose==='asking'))return 'asking';const working=live.find(s=>busy(s.pose));if(working)return working.pose;if(live[0]&&time-live[0].updated<15&&['happy','error'].includes(live[0].pose))return live[0].pose;return Object.values(state.sessions).every(s=>time-s.updated>600)&&Object.keys(state.sessions).length?'sleeping':'idle';}
function petPayload(state,prefs,requests,time=now()) {const live=liveSessions(state,time),pose=currentPose(state,requests,time),convert=s=>({pose:s.pose==='error'?'oops':s.pose==='happy'&&s.toolCount>=8?'proud':s.pose,event:s.event,ts:s.updated,tool:s.tool});const focus=live.find(s=>busy(s.pose)||s.pose==='asking')??live[0];return {sessions:Object.fromEntries(live.map(s=>[s.id,convert(s)])),state:requests.length?{pose:'asking',event:'PermissionRequest',ts:time}:focus?convert(focus):undefined,registeredAt:prefs.registeredAt,quota:{low:!!(focus?.quotaUpdated&&time-focus.quotaUpdated<900&&focus.quota.some(q=>q.used>=90))}};}
function clawdState(state,requests,time=now()) {const p=currentPose(state,requests,time),live=liveSessions(state,time),count=live.filter(s=>busy(s.pose)).length;let pair={thinking:['thinking','clawd-working-thinking.svg'],reading:['working','clawd-idle-reading.svg'],searching:['working','clawd-idle-reading.svg'],writing:['working','clawd-working-typing.svg'],running:['working','clawd-working-typing.svg'],delegating:['juggling','clawd-headphones-groove.svg'],asking:['notification','clawd-notification.svg'],compact:['sweeping','clawd-working-sweeping.svg'],happy:['attention','clawd-happy.svg'],error:['error','clawd-error.svg']}[p]??['idle','clawd-idle-follow.svg'];if(!['asking','compact','happy','error'].includes(p)){if(count>=3)pair=['working','clawd-working-building.svg'];else if(count>=2)pair=['working','clawd-headphones-groove.svg'];if(live.some(s=>s.agents.length>=2))pair=['juggling','clawd-working-juggling.svg'];}return pair;}
function validEmail(x){return typeof x==='string'&&/^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}$/i.test(x);}
function senderAllowed(address){if(!validEmail(address))return false;const domain=address.split('@').at(-1).toLowerCase();return domain==='anthropic.com'||domain.endsWith('.anthropic.com');}
function validateSettings(input,old=defaults()) {const value={...old};for(const key of ['monitoring','desktopCard','cardOnTop','notify','showPet','approvals','notifications','alwaysOnTop'])if(typeof input[key]==='boolean')value[key]=input[key];if(typeof input.email==='string'){value.email=input.email.trim().toLowerCase();if(value.email&&!validEmail(value.email))throw Error('请输入有效的邮箱地址。');}if('registeredAt'in input){if(input.registeredAt!==null&&(!Number.isFinite(input.registeredAt)||input.registeredAt>now()||input.registeredAt<0))throw Error('注册时间无效。');value.registeredAt=input.registeredAt;}if('intervalMinutes'in input){if(![1,3,5,10,15,30,60].includes(input.intervalMinutes))throw Error('检查间隔无效。');value.intervalMinutes=input.intervalMinutes;}if('petScale'in input){if(!Number.isFinite(input.petScale)||input.petScale<0.6||input.petScale>1.5)throw Error('桌宠大小无效。');value.petScale=input.petScale;}return value;}
function monitorStatus(prefs,snapshot,time=now()){if(!prefs.email||!prefs.registeredAt)return '等待连接';if(!prefs.monitoring)return '检测已暂停';if(snapshot.error)return '检查未完成';if(!snapshot.lastChecked)return '等待首次检查';if(time-snapshot.lastChecked>Math.max(15,prefs.intervalMinutes*3)*60)return '结果待更新';return snapshot.hits?.length?'发现匹配邮件':'未发现匹配邮件';}
function rootPath(){return process.env.QISHI_CLAUDE_HOME||path.join(process.env.LOCALAPPDATA||path.join(os.homedir(),'.local','share'),'QishiClaude');}
function readJSON(file,fallback=null){try{if(fs.statSync(file).size>4_000_000)return fallback;return JSON.parse(fs.readFileSync(file,'utf8'));}catch{return fallback;}}
function writeJSON(file,value){fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});const tmp=file+'.'+crypto.randomUUID()+'.tmp';try{fs.writeFileSync(tmp,JSON.stringify(value,null,2),{mode:0o600,flag:'wx'});fs.renameSync(tmp,file);}finally{try{fs.unlinkSync(tmp);}catch{}}}
async function locked(root,name,action){fs.mkdirSync(root,{recursive:true,mode:0o700});const lock=path.join(root,name+'.lock'),deadline=Date.now()+2500;let fd;while(fd===undefined){try{fd=fs.openSync(lock,'wx',0o600);fs.writeSync(fd,JSON.stringify({pid:process.pid,time:now()}));}catch(e){if(e.code!=='EEXIST')throw e;const owner=readJSON(lock);let stale=false;if(owner?.pid){try{process.kill(owner.pid,0);}catch(err){stale=err.code==='ESRCH';}}else try{stale=Date.now()-fs.statSync(lock).mtimeMs>10000;}catch{}if(stale){try{fs.unlinkSync(lock);}catch{}}if(Date.now()>deadline)throw Error('数据正被其他进程使用，请重试。');await new Promise(r=>setTimeout(r,20));}}try{return await action();}finally{fs.closeSync(fd);try{fs.unlinkSync(lock);}catch{}}}
module.exports={now,hash,titles,events,busy,percent,empty,defaults,toolPose,project,ingest,statusline,liveSessions,currentPose,petPayload,clawdState,validEmail,senderAllowed,validateSettings,monitorStatus,rootPath,readJSON,writeJSON,locked};

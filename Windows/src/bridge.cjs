'use strict';
const fs=require('node:fs');const path=require('node:path');const {spawn}=require('node:child_process');const crypto=require('node:crypto');const C=require('./core.cjs');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
function alive(pid){if(!Number.isInteger(pid)||pid<=0)return false;try{process.kill(pid,0);return true;}catch{return false;}}
function liveApp(root){const b=C.readJSON(path.join(root,'heartbeat.json'));return !!(b&&C.now()-b.time<4&&b.time<=C.now()+2&&b.approvals===true&&alive(b.pid));}
function requestCurrent(root,r){const s=C.readJSON(path.join(root,'claude-state.json'),C.empty()).sessions[r.session];return !!(s&&s.turn===r.turn&&!s.closed&&!['happy','error'].includes(s.pose)&&r.expires>C.now()&&alive(r.pid));}
async function permission(root,input){if(!liveApp(root)||typeof input.tool_name!=='string'||!input.tool_name||['AskUserQuestion','ExitPlanMode','EnterPlanMode'].includes(input.tool_name)||!input.tool_input||typeof input.tool_input!=='object')return;
 const detail=JSON.stringify(input.tool_input,null,2);if(Buffer.byteLength(detail)>65536)return;
 const sid=C.hash(input.session_id),session=C.readJSON(path.join(root,'claude-state.json'),C.empty()).sessions[sid];if(!session)return;
 const id=crypto.randomUUID(),r={id,session:sid,project:session.cwd,tool:input.tool_name,input:detail,turn:session.turn,expires:C.now()+90,pid:process.pid};
 const request=path.join(root,'requests',id+'.json'),response=path.join(root,'responses',id+'.json');C.writeJSON(request,r);
 try{while(liveApp(root)&&requestCurrent(root,r)){const result=C.readJSON(response);if(result?.id===id){if(!['allow','deny'].includes(result.choice))return;const decision={behavior:result.choice};if(result.choice==='deny')decision.message='用户在栖时中拒绝了这一次操作。';process.stdout.write(JSON.stringify({hookSpecificOutput:{hookEventName:'PermissionRequest',decision}})+'\n');return;}await sleep(150);}}finally{for(const file of [request,response])try{fs.unlinkSync(file);}catch{}}
}
async function relay(root,data,input){const previous=C.readJSON(path.join(root,'statusline-previous.json'));if(previous?.command&&!isOwned(previous)){
 await new Promise(resolve=>{let child;try{const command=statusShell(previous);child=spawn(command.file,command.args,{windowsHide:true,stdio:['pipe','pipe','pipe'],cwd:typeof input.cwd==='string'&&fs.existsSync(input.cwd)?input.cwd:undefined});}catch{return resolve();}const timer=setTimeout(()=>{child.kill();resolve();},3000);child.stdout.pipe(process.stdout,{end:false});child.stderr.resume();child.stdin.on('error',()=>{});child.stdin.end(data);child.once('error',()=>{clearTimeout(timer);resolve();});child.once('exit',()=>{clearTimeout(timer);resolve();});});return;}
 const parts=[String(input.model?.display_name??'Claude').slice(0,100)];for(const [id,label]of[['five_hour','5h'],['seven_day','7d']]){const used=C.percent(input.rate_limits?.[id]?.used_percentage);if(used!==null)parts.push(`${label} ${Math.trunc(used)}% 已用`);}process.stdout.write(parts.join(' · ')+'\n');
}
function commandText(entry) {
 if(typeof entry?.command!=='string')return '';
 const encoded=entry.command.match(/(?:^|\s)-EncodedCommand\s+([A-Za-z0-9+/=]+)(?:\s|$)/i);
 if(encoded){try{return Buffer.from(encoded[1],'base64').toString('utf16le');}catch{}}
 return entry.command;
}
function isOwned(entry){const command=commandText(entry);return command.includes('--qishi-hook')||command.includes('--qishi-statusline')||command.includes('qishi-bridge-launch.ps1');}
// Match Claude Code's Windows statusline shell choice: Git Bash when installed,
// otherwise PowerShell. A saved explicit shell choice takes precedence.
function statusShell(previous,{platform=process.platform,env=process.env,exists=fs.existsSync}={}) {
 if(platform!=='win32')return {file:'/bin/sh',args:['-c',previous.command]};
 const join=path.win32.join;
 const paths=(env.PATH||env.Path||'').split(';').map(x=>x.replace(/^"|"$/g,'')).filter(x=>x&&path.win32.isAbsolute(x));
 const candidates=[env.CLAUDE_CODE_GIT_BASH_PATH];
 for(const base of [env.ProgramFiles,env['ProgramFiles(x86)']])if(base)candidates.push(join(base,'Git','bin','bash.exe'),join(base,'Git','usr','bin','bash.exe'));
 if(env.LOCALAPPDATA)candidates.push(join(env.LOCALAPPDATA,'Programs','Git','bin','bash.exe'));
 for(const dir of paths){
  if(exists(join(dir,'git.exe'))||/\\Git\\(?:bin|cmd|usr\\bin)$/i.test(dir))candidates.push(join(dir,'bash.exe'),join(dir,'..','bin','bash.exe'),join(dir,'..','..','bin','bash.exe'));
 }
 const bash=candidates.find(x=>x&&path.win32.isAbsolute(x)&&exists(x));
 if(previous.shell!=='powershell'&&bash)return {file:bash,args:['-c',previous.command]};
 if(previous.shell==='bash')throw Error('原状态栏需要 Git Bash，但当前没有找到 Git Bash。');
 const powerCandidates=paths.map(dir=>join(dir,'pwsh.exe'));
 if(env.ProgramFiles)powerCandidates.push(join(env.ProgramFiles,'PowerShell','7','pwsh.exe'));
 powerCandidates.push(join(env.SystemRoot||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe'));
 return {file:powerCandidates.find(exists)||'powershell.exe',args:['-NoProfile','-NonInteractive','-Command',previous.command]};
}
async function run(args=process.argv.slice(2)){const hook=args.indexOf('--qishi-hook'),status=args.includes('--qishi-statusline');if(hook<0&&!status)return false;try{let bytes=0,chunks=[];for await(const chunk of process.stdin){bytes+=chunk.length;if(bytes>2_000_000)return true;chunks.push(chunk);}const data=Buffer.concat(chunks),input=JSON.parse(data.toString('utf8'));if(!input||typeof input!=='object')return true;const root=C.rootPath();await C.locked(root,'state',()=>{const file=path.join(root,'claude-state.json'),state=C.readJSON(file,C.empty());if(status)C.statusline(state,input);else C.ingest(state,input,args[hook+1]);C.writeJSON(file,state);});if(status)await relay(root,data,input);else if(args[hook+1]==='PermissionRequest'&&typeof input.session_id==='string')await permission(root,input);}catch{/* A companion must leave Claude's native flow intact. */}return true;}
if(require.main===module)run().then(()=>{});
module.exports={run,alive,liveApp,requestCurrent,isOwned,commandText,statusShell};

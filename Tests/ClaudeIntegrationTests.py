#!/usr/bin/env python3
"""End-to-end tests: real helper processes; isolated settings; no account/API calls."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())
passed = 0
def check(condition, label):
    global passed
    assert condition, label
    passed += 1
    print('PASS:', label)

with tempfile.TemporaryDirectory(prefix='qishi-claude-test-') as temp:
    base = Path(temp)
    root = base / 'state'
    config = base / "claude's settings"
    config.mkdir()
    env = dict(os.environ, QISHI_CLAUDE_HOME=str(root), CLAUDE_CONFIG_DIR=str(config))
    original = {'model': 'existing-model', 'permissions': {'deny': ['Bash(rm:*)']},
                'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type':'command','command':'echo existing'}]}]},
                'statusLine': {'type':'command','command': "printf 'existing-status'",'padding': 2}}
    settings = config / 'settings.json'
    settings.write_text(json.dumps(original))
    def invoke(args, payload=None):
        return subprocess.run([binary] + args, input=json.dumps(payload) if payload is not None else '', text=True,
                              capture_output=True, env=env, timeout=10, check=True)
    def hook(event, sid='one', **extra):
        return invoke(['--qishi-hook', event], {'session_id':sid,'cwd':'/Projects/Example','hook_event_name':event, **extra})
    def state(): return json.loads((root / 'claude-state.json').read_text())
    def session(sid='one'): return state()['sessions'][hashlib.sha256(sid.encode()).hexdigest()]

    invoke(['install',binary]); first = json.loads(settings.read_text())
    invoke(['install',binary]); second = json.loads(settings.read_text())
    check(first == second, 'repeated installation is idempotent')
    check(second['permissions'] == original['permissions'] and second['model'] == original['model'], 'preserves model and all permission rules')
    check(second['hooks']['PreToolUse'][0] == original['hooks']['PreToolUse'][0], 'preserves other hooks and matchers')
    check(len(list((root / 'Backups').glob('*.json'))) == 2, 'backs up settings before each change')
    # Shell quoting must support apostrophes and spaces in the installed helper path.
    cmd = second['hooks']['SessionStart'][0]['hooks'][0]['command']
    result = subprocess.run(['/bin/sh','-c',cmd], input=json.dumps({'session_id':'shell'}), env=env, text=True, capture_output=True, timeout=10)
    check(result.returncode == 0 and session('shell')['pose'] == 'idle', 'installed command runs through the real shell')

    hook('UserPromptSubmit', prompt='PRIVATE USER PROMPT', transcript_path='/private/conversation.jsonl')
    hook('PreToolUse', tool_name='Read', tool_use_id='a', tool_input={'file_path':'PRIVATE FILE CONTENT'})
    hook('PreToolUse', tool_name='Bash', tool_use_id='b')
    hook('PostToolUse', tool_name='Bash', tool_use_id='b')
    check(session()['pose'] == 'reading' and len(session()['activeTools']) == 1, 'parallel tools retain the remaining active work')
    check('PRIVATE' not in (root / 'claude-state.json').read_text() and 'transcript_path' not in (root / 'claude-state.json').read_text(), 'activity never saves prompts, tool inputs, or transcript paths')
    hook('PostToolUseFailure', tool_name='Read', tool_use_id='a')
    check(session()['pose'] == 'error', 'tool failure is visible')
    hook('SubagentStart',agent_id='sub1'); hook('SubagentStart',agent_id='sub2'); hook('SubagentStop',agent_id='sub1')
    check(session()['agents'] == ['sub2'] and session()['pose'] == 'delegating', 'one completed subagent does not hide another')
    hook('PreCompact'); check(session()['pose'] == 'compact', 'compaction has its own state')
    hook('PreToolUse', tool_name='AskUserQuestion',tool_use_id='ask'); check(session()['pose'] == 'asking','questions wait for the user')
    hook('Stop'); check(session()['pose'] == 'happy' and not session()['activeTools'], 'Stop clears active tools and celebrates')
    hook('SessionEnd'); check(session()['closed'], 'SessionEnd closes the session')

    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        list(pool.map(lambda i: hook('PreToolUse',sid=f'parallel-{i}',tool_name='Edit',tool_use_id=str(i)),range(32)))
    check(all(hashlib.sha256(f'parallel-{i}'.encode()).hexdigest() in state()['sessions'] for i in range(32)), '32 concurrent hook writers lose no sessions')
    payload = {'session_id':'quota', 'model':{'display_name':'Claude Test'},'context_window':{'used_percentage':36},
               'rate_limits': {'five_hour':{'used_percentage':0,'resets_at':time.time()+3600}, 'seven_day':{'used_percentage':92}}}
    out = invoke(['--qishi-statusline'],payload)
    check(out.stdout == 'existing-status', 'existing status line output remains unchanged')
    check(session('quota')['quota'][0]['used'] == 0 and session('quota')['quota'][1]['used'] == 92, 'real zero quota and nonzero quota stay distinct')
    invoke(['--qishi-statusline'], {'session_id':'quota','rate_limits':{'five_hour':{'used_percentage':True}}})
    check(session('quota')['quota'] == [], 'malformed quota is not displayed as a number')
    invoke(['--qishi-statusline'], {'session_id':'quota'})
    check(session('quota')['quota'] == [], 'absent quota is unknown, never fabricated as zero')

    before = time.monotonic()
    result = hook('PermissionRequest',tool_name='Bash',tool_input={'command':'echo hello'})
    check(time.monotonic()-before < 2 and not result.stdout, 'no running app means immediate native permission handling')
    def heartbeat():
        (root / 'heartbeat.json').write_text(json.dumps({'time':time.time(),'pid':os.getpid(),'approvals':1}))
    def request(choice):
        hook('UserPromptSubmit',sid='approval')
        heartbeat()
        p = subprocess.Popen([binary,'--qishi-hook','PermissionRequest'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
        p.stdin.write(json.dumps({'session_id':'approval','tool_name':'Bash','tool_input':{'command':'echo example'},'cwd':'/Projects/Example'}));p.stdin.close();p.stdin=None
        deadline=time.monotonic()+3
        files=[]
        while time.monotonic()<deadline:
            files=list((root/'requests').glob('*.json'))
            if files: break
            time.sleep(.03)
        assert files, 'request appeared'
        r=json.loads(files[0].read_text())
        assert r['input'] == '{\n  "command" : "echo example"\n}' or json.loads(r['input']) == {'command':'echo example'}
        if choice=='cancel': hook('UserPromptSubmit',sid='approval')
        elif choice=='closed': (root/'heartbeat.json').unlink()
        else: (root/'responses'/f"{r['id']}.json").write_text(json.dumps({'id':r['id'],'choice':choice}))
        output,error=p.communicate(timeout=5)
        assert p.returncode==0,error
        assert not files[0].exists(), 'request removed'
        return output
    check(json.loads(request('allow'))['hookSpecificOutput']['decision']=={'behavior':'allow'}, 'allow replies only to this permission request without persistent rules')
    check(json.loads(request('deny'))['hookSpecificOutput']['decision']['behavior']=='deny', 'deny returns the documented Claude decision format')
    check(request('native')=='','native handling returns no permission decision')
    check(request('cancel')=='','new user turn cancels an outdated approval')
    check(request('closed')=='','closing companion falls back without a synthetic denial')

    # Later changes made by the user must survive uninstall.
    current=json.loads(settings.read_text());current['newUserSetting']=True;settings.write_text(json.dumps(current))
    invoke(['remove',binary]); restored=json.loads(settings.read_text())
    expected=dict(original,newUserSetting=True)
    check(restored==expected, 'uninstall restores the prior status line while retaining later user changes')
    settings.write_text('{invalid-json')
    bad=subprocess.run([binary,'install',binary],env=env,text=True,capture_output=True)
    check(bad.returncode!=0 and settings.read_text()=='{invalid-json', 'invalid settings are never overwritten')
print(f'PASS: {passed} Claude integration checks; no live Claude settings or accounts used')

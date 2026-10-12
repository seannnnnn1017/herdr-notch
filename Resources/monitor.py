#!/usr/bin/env python3
"""Read-only Herdr inventory and Codex / Claude usage bridge. No inference calls."""
import json, os, re, sys, shutil, subprocess, threading, queue, time, signal, base64, ntpath
from datetime import datetime, timedelta
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

def binary(name):
    override = os.environ.get(name.upper() + '_BIN')
    choices = [override, shutil.which(name), os.path.expanduser('~/.local/bin/' + name), '/opt/homebrew/bin/' + name, '/usr/local/bin/' + name]
    return next((p for p in choices if p and os.path.isfile(p)), name)

# Herdr agent kinds the notch lists (see `herdr agent start --kind`).
AGENT_KINDS = ('codex', 'claude')
STATE = Path(os.environ.get('HERDR_NOTCH_STATE') or Path.home() / 'Library/Application Support/Herdr Notch')

def agent_kind(agent):
    name = (agent or '').lower()
    return next((kind for kind in AGENT_KINDS if kind in name), None)

class QueryTimeout(RuntimeError):
    pass

def call(args, timeout=None):
    timeout = timeout if timeout is not None else (15 if '--machine' in args else 8)
    return run_json([binary('herdr')] + args, timeout)

def run_json(command, timeout, cwd=None):
    # Own a new process group so timeout cleanup touches only this query,
    # including its SSH child, never the existing client/server or SSH master.
    try: p = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True, start_new_session=True, cwd=cwd)
    except FileNotFoundError: raise RuntimeError('找不到 ' + os.path.basename(command[0])) from None
    try:
        stdout, stderr = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try: os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        try: p.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            p.stdout.close(); p.stderr.close(); p.wait(timeout=1)
        raise QueryTimeout('狀態讀取逾時，請稍後重試') from None
    if p.returncode:
        # Herdr reports API errors as one JSON object; keep its message.
        message = None
        for stream in (stderr, stdout):
            try: message = json.loads(stream)['error']['message']; break
            except (ValueError, KeyError, TypeError): pass
        raise RuntimeError(message or (stderr.strip().splitlines()[0] if stderr.strip() else 'Herdr 未回應'))
    return json.loads(stdout)

def windows_metadata(profile):
    if not profile or not profile.get('target'): return None
    profile_id = profile.get('id', '')
    if len(profile_id) != 32 or any(c not in '0123456789abcdef' for c in profile_id): return None
    state_dir = Path(os.environ.get('XDG_STATE_HOME') or str(Path.home()/'.local/state'))
    path = state_dir/'herdr/client/ssh-metadata'/f'{profile_id}.json'
    try:
        if path.is_symlink() or path.stat().st_size > 16384: return None
        data = json.loads(path.read_text())
    except (OSError, ValueError): return None
    if data.get('version') != 1: return None
    metadata = data.get('metadata', {})
    if data.get('target') != profile['target'] or data.get('session') != profile.get('session', 'default'): return None
    executable = metadata.get('executable', '')
    if metadata.get('os') != 'windows' or not isinstance(executable, str) or not ntpath.isabs(executable) or not ntpath.splitdrive(executable)[0]: return None
    return metadata

def endpoint_api(prefix, args, profile=None):
    metadata = windows_metadata(profile)
    if metadata is None:
        return call(prefix + args)
    # Same public API and saved session. Calling the Windows executable
    # directly avoids the intermittent stdio bridge startup hang.
    def quote(value): return "'" + value.replace("'", "''") + "'"
    script = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $OutputEncoding = [Console]::OutputEncoding; & " + quote(metadata['executable']) + " --session " + quote(profile.get('session', 'default')) + " " + " ".join(quote(a) for a in args) + "; exit $LASTEXITCODE"
    encoded = base64.b64encode(script.encode('utf-16le')).decode('ascii')
    command = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=5', '--', profile['target'], 'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + encoded]
    return run_json(command, 15)

def read_snapshot(prefix, profile=None):
    return endpoint_api(prefix, ['api', 'snapshot'], profile)['result']['snapshot']

def query_error(error):
    """Keep one endpoint's diagnostics short enough for the notch surface."""
    message = str(error).strip().splitlines()
    message = message[0] if message else 'Herdr 未回應'
    return message if len(message) <= 180 else message[:177] + '…'

def inventory(emit=None):
    agents, errors, targets, machines = [], [], [], []
    snapshots = {}
    profiles_by_id = {}
    local = dict(id='local', label='Local', state='online', agentCount=0)
    machines.append(local)
    try:
        sessions = call(['session', 'list', '--json'])['sessions']
        for s in sessions:
            if s.get('running'):
                targets.append((local, s['name'], ['--session', s['name']]))
    except Exception as e:
        local['state'] = 'offline'
        errors.append('Local: ' + query_error(e))
    try:
        for profile in call(['machine', 'list', '--json']):
            if not profile.get('enabled'): continue
            profiles_by_id[profile['id']] = profile
            machine = dict(id=profile['id'], label=profile['label'], state='online', agentCount=0)
            machines.append(machine)
            targets.append((machine, profile.get('session', 'default'), ['--machine', profile['id']]))
    except Exception as e:
        errors.append('遠端機器清單: ' + query_error(e))

    if emit is not None:
        active_machines = {machine['id'] for machine, _, _ in targets}
        emit(dict(type='targets',
            machines=[dict(machine, state='checking' if machine['id'] in active_machines else machine['state']) for machine in machines],
            targets=[dict(machineId=machine['id'], session=session) for machine, session, _ in targets],
            errors=list(errors), updated=time.time()))

    def read_target(target):
        machine, session, prefix = target
        try:
            snapshot = read_snapshot(prefix, profiles_by_id.get(machine['id']))
            rows = snapshot['agents']
            labels = {w['workspace_id']: w.get('label', '') for w in snapshot.get('workspaces', [])}
            result = []
            for a in rows:
                kind = agent_kind(a.get('agent'))
                if kind is None: continue
                pane = a['pane_id']
                result.append(dict(id=machine['id']+':'+session+':'+pane, machineId=machine['id'], machine=machine['label'], pane=pane, session=session, title=a.get('terminal_title_stripped') or a.get('name') or pane, cwd=a.get('foreground_cwd') or a.get('cwd') or '', status=a.get('agent_status', 'unknown'), agent=kind, activity=a.get('state_change_seq'), focused=bool(a.get('focused')), workspace=labels.get(a.get('workspace_id'), '')))
            machine['workspaces'] = sorted(set(labels.values()))
            return machine, session, result, None, snapshot
        except Exception as e:
            return machine, session, [], machine['label'] + '/' + session + ': ' + query_error(e), None

    rows_by_target, errors_by_target = {}, {}
    # Publish each completed endpoint before waiting for a slow/offline PC.
    # Keep final inventory order stable for callers of the original API.
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(read_target, target) for target in targets]
        for future in as_completed(futures):
            machine, session, rows, error, snapshot = future.result()
            key = (machine['id'], session)
            rows_by_target[key] = rows
            if snapshot is not None:
                snapshots[key] = snapshot
            machine['agentCount'] += len(rows)
            if error:
                machine['state'] = 'offline'
                errors_by_target[key] = error
            if emit is not None:
                emit(dict(type='target', machineId=machine['id'], session=session,
                    agents=rows, error=error, state='offline' if error else 'online',
                    workspaces=machine.get('workspaces', []), updated=time.time()))
    for machine, session, _ in targets:
        key = (machine['id'], session)
        agents.extend(rows_by_target.get(key, []))
        if key in errors_by_target:
            errors.append(errors_by_target[key])
    navigation = {}
    endpoints = [('local', 'default', snapshots.get(('local', 'default')))] + [
        (machine['id'], session, snapshots.get((machine['id'], session)))
        for machine, session, _ in targets if machine['id'] != 'local'
    ]
    navigation = navigation_plans(endpoints)
    result = dict(agents=agents, machines=machines, errors=errors, navigation=navigation, updated=time.time())
    if emit is not None:
        emit(dict(type='done', errors=errors, machines=machines, agents=agents, updated=result['updated']))
    return result

def stream_inventory():
    def emit(event):
        print(json.dumps(event, ensure_ascii=False), flush=True)
    inventory(emit=emit)

def focus(machine_id, session, pane):
    """Focus one agent through Herdr's own API. Since Herdr 0.9.1 this also
    moves attached clients already viewing that server; no keystrokes."""
    if machine_id == 'local':
        if session != 'default':
            raise RuntimeError('Herdr 視窗只顯示 default 本機 session')
        return call(['agent', 'focus', pane])['result']['agent']
    profile = next((p for p in call(['machine', 'list', '--json']) if p.get('enabled') and p['id'] == machine_id), None)
    if not profile or profile.get('session', 'default') != session:
        raise RuntimeError('遠端連線設定已變更，請重新整理')
    return endpoint_api(['--machine', machine_id], ['agent', 'focus', pane], profile)['result']['agent']

def launch_cwd(path):
    """Work in the dropped file's repository, else its folder."""
    base = path if os.path.isdir(path) else os.path.dirname(path)
    try:
        top = subprocess.run(['git', '-C', base, 'rev-parse', '--show-toplevel'], capture_output=True, text=True, timeout=3)
        if top.returncode == 0 and top.stdout.strip(): return top.stdout.strip()
    except (OSError, subprocess.TimeoutExpired): pass
    return base

def pasted_paths(paths):
    """What a terminal pastes when files are dropped on it: shell-escaped
    paths, wrapped as one bracketed paste. An agent's startup dialog (folder
    trust, update notice) ignores a paste, so it can never answer one."""
    safe = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:,@%')
    escaped = [''.join(c if c in safe or ord(c) > 127 else '\\' + c for c in path) for path in paths]
    return '\x1b[200~' + ' '.join(escaped) + ' \x1b[201~'

def launch_tab(kind, paths):
    """Open a focused tab in the local default session for a new agent."""
    if kind not in AGENT_KINDS: raise RuntimeError('不支援的 agent：' + kind)
    paths = [os.path.abspath(p) for p in paths]
    missing = [p for p in paths if not os.path.exists(p)]
    if not paths or missing: raise RuntimeError('找不到檔案：' + (missing[0] if missing else ''))
    cwd = launch_cwd(paths[0])
    label = (os.path.basename(paths[0].rstrip('/')) or 'drop')[:40]
    created = call(['tab', 'create', '--cwd', cwd, '--label', label, '--focus'])['result']
    workspace_id = created['tab']['workspace_id']
    workspace = call(['workspace', 'get', workspace_id])['result']['workspace']
    return dict(pane=created['root_pane']['pane_id'], tab=created['tab']['tab_id'], workspace=workspace.get('label', ''), cwd=cwd, label=label)

def initial_prompt(question, paths):
    """One line: Herdr refuses agent arguments containing newlines. Paths are
    quoted so names with spaces stay whole; the agent opens them itself."""
    line = ' '.join(question.split())
    files = ' '.join(json.dumps(path, ensure_ascii=False) for path in paths)
    return line + ('  （檔案：' + files + '）' if files else '')

def launch_agent(kind, pane, paths, prompt=None, start_timeout=8000):
    """Start the agent in the new pane and hand it the dropped paths: with a
    question, as its initial prompt; without one, pasted into its input."""
    if kind not in AGENT_KINDS: raise RuntimeError('不支援的 agent：' + kind)
    paths = [os.path.abspath(p) for p in paths]
    name = 'notch-%s-%d' % (kind, int(time.time()) % 1000000)
    question = ' '.join((prompt or '').split())
    start = ['agent', 'start', name, '--kind', kind, '--pane', pane, '--timeout', str(start_timeout)]
    if question: start += ['--', initial_prompt(question, paths)]
    error = None
    try: call(start, timeout=start_timeout / 1000 + 10)
    except Exception as e: error = query_error(e)
    # Herdr moves attached clients for agent focus; the tab may have been
    # created while the client was still on another machine.
    try: call(['agent', 'focus', pane])
    except Exception: pass
    if question:
        # A working agent is not "ready for input", so readiness can time
        # out although it started and is answering.
        if error:
            try: call(['agent', 'get', pane]); error = None
            except Exception: pass
        return dict(submitted=error is None, pasted=False, copied=False, startError=error)
    pasted = False
    try:
        call(['pane', 'send-text', pane, pasted_paths(paths)])
        time.sleep(0.6)
        visible = subprocess.run([binary('herdr'), 'pane', 'read', pane, '--source', 'visible'], capture_output=True, text=True, timeout=5).stdout
        # A wrapped long path may be split across rows; compare without
        # whitespace. The agent may show the name escaped or resolved.
        name = os.path.basename(paths[0].rstrip('/'))
        escaped = pasted_paths([name])[len('\x1b[200~'):-len('\x1b[201~')]
        screen = ''.join(visible.split())
        pasted = any(''.join(form.split()) in screen for form in (name, escaped))
    except Exception: pass
    copied = False
    if not pasted:
        # A startup dialog swallowed the paste, or the agent is not up yet.
        try:
            plain = pasted_paths(paths)[len('\x1b[200~'):-len('\x1b[201~')]
            subprocess.run(['pbcopy'], input=plain, text=True, timeout=3, check=True)
            copied = True
        except (OSError, subprocess.SubprocessError): pass
    return dict(submitted=False, pasted=pasted, copied=copied, startError=error)

def focus_tab(tab):
    return call(['tab', 'focus', tab])['result']

def navigation_plans(endpoints):
    rows = []
    for endpoint_id, session, snapshot in endpoints:
        # Rows before an unavailable endpoint are still unambiguous. Rows
        # after it depend on its unknown cached topology and must be omitted.
        if snapshot is None: break
        if len(endpoints) > 1:
            rows.append(None)
        for workspace in snapshot['workspaces']:
            rows.append(None)
            for tab in snapshot['tabs']:
                if tab['workspace_id'] == workspace['workspace_id']:
                    rows.extend(endpoint_id + ':' + session + ':' + p['pane_id'] for p in snapshot['panes'] if p['tab_id'] == tab['tab_id'])
    first = next((i for i, row in enumerate(rows) if row is not None), 0)
    return {row: i - first for i, row in enumerate(rows) if row is not None}

def codex_quota():
    p = subprocess.Popen([binary('codex'), 'app-server', '--listen', 'stdio://'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    q = queue.Queue()
    def reader():
        for line in p.stdout:
            try: q.put(json.loads(line))
            except ValueError: pass
        q.put(None)
    threading.Thread(target=reader, daemon=True).start()
    def send(message):
        p.stdin.write(json.dumps(message)+'\n'); p.stdin.flush()
    def rpc(id, method, params=None):
        send(dict(id=id, method=method, params=params or {}))
        deadline = time.monotonic()+15
        while time.monotonic()<deadline:
            message = q.get(timeout=max(.1, deadline-time.monotonic()))
            if message is None: raise RuntimeError('Codex server exited')
            if message.get('id') == id:
                if 'error' in message: raise RuntimeError(message['error'].get('message', 'Codex error'))
                return message['result']
        raise RuntimeError('Quota request timed out')
    try:
        rpc(1, 'initialize', {'clientInfo': {'name':'herdr_notch', 'title':'Herdr Notch', 'version':'0.4.0'}})
        send({'method':'initialized','params':{}})
        result = rpc(2, 'account/rateLimits/read')
        buckets = result.get('rateLimitsByLimitId') or {'codex':result.get('rateLimits')}
        windows=[]
        for key,bucket in buckets.items():
            if not bucket: continue
            for kind in ['primary','secondary']:
                w=bucket.get(kind)
                if w:
                    minutes=w.get('windowDurationMins') or 0
                    label = window_label(minutes)
                    windows.append(dict(id=key+kind, label=label if key == 'codex' else (bucket.get('limitName') or key)+' · '+label, remaining=max(0,min(100,100-w['usedPercent'])), resetsAt=w.get('resetsAt'), plan=bucket.get('planType')))
        return dict(windows=windows, updated=time.time(), error=None)
    finally:
        p.terminate()
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: p.kill(); p.wait()

def window_label(minutes):
    return str(minutes//1440)+' 天' if minutes>=1440 else str(minutes//60)+' 小時' if minutes>=60 else str(minutes)+' 分鐘'

USAGE_LINE = re.compile(r'^\s*(.+?):\s*(\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s+(.+?))?\s*$')
RESET_TIME = re.compile(r'^(?:([A-Za-z]{3})[a-z]*\s+(\d{1,2})(?:,?\s+at)?\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)(?:\s*\(([^)]+)\))?$', re.I)
MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec']

def parse_reset(text, now):
    """'Oct 12 at 4:09pm (Asia/Taipei)' -> epoch seconds of the next such time."""
    match = RESET_TIME.match((text or '').strip())
    if not match: return None
    month, day, hour, minute, half, zone = match.groups()
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo(zone) if zone else None
    except Exception: tz = None
    current = datetime.fromtimestamp(now, tz).astimezone(tz)
    hour = int(hour) % 12 + (12 if half.lower() == 'pm' else 0)
    try:
        if month:
            if month.lower() not in MONTHS: return None
            candidate = current.replace(month=MONTHS.index(month.lower()) + 1, day=int(day), hour=hour, minute=int(minute or 0), second=0, microsecond=0)
            # No year is printed: a date well in the past means next year.
            if candidate < current - timedelta(days=30): candidate = candidate.replace(year=candidate.year + 1)
        else:
            candidate = current.replace(hour=hour, minute=int(minute or 0), second=0, microsecond=0)
            if candidate < current: candidate += timedelta(days=1)
    except ValueError: return None
    return candidate.timestamp()

def usage_windows(text, now):
    """Windows from Claude Code's /usage report, e.g.
    'Current session: 75% used · resets Oct 12 at 4:10pm (Asia/Taipei)'."""
    windows = []
    for line in text.splitlines():
        match = USAGE_LINE.match(line)
        if not match: continue
        name, used, reset = match.groups()
        scope = re.search(r'\(([^)]+)\)', name)
        if name.lower().startswith('current session'): label = '5 小時'
        elif name.lower().startswith('current week'):
            label = '7 天' if not scope or scope.group(1).lower() == 'all models' else '7 天 · ' + scope.group(1)
        else: label = name
        windows.append(dict(id='claude-%d' % len(windows), label=label, remaining=max(0, min(100, 100-float(used))), resetsAt=parse_reset(reset, now), plan=None))
    return windows

def claude_usage_live(now=None, max_age=120, fresh=False):
    """Account-wide limits from `claude -p /usage`: a local command, so no
    model call and no tokens, and it covers the desktop app and other
    devices, which the statusLine record cannot see."""
    now = now or time.time()
    STATE.mkdir(parents=True, exist_ok=True)
    cache, disabled = STATE / 'claude-usage-live.json', STATE / 'claude-usage-live.disabled'
    if not fresh:
        try:
            cached = json.loads(cache.read_text())
            if 0 <= now - cached['updated'] < max_age: return cached
        except (OSError, ValueError, KeyError, TypeError): pass
    if disabled.exists(): raise RuntimeError('這個版本的 Claude Code 不支援離線查詢用量')
    # Empty transcripts are not written with --no-session-persistence.
    reply = run_json([binary('claude'), '-p', '/usage', '--output-format', 'json', '--no-session-persistence'], 25, cwd=str(STATE))
    if reply.get('local_command') != 'usage':
        # An older CLI would send "/usage" to the model. Never repeat that.
        disabled.write_text('claude -p /usage was not handled as a local command\n')
        raise RuntimeError('這個版本的 Claude Code 不支援離線查詢用量')
    windows = usage_windows(reply.get('result') or '', now)
    if not windows: raise RuntimeError('Claude Code 沒有回報訂閱用量（可能不是訂閱帳號）')
    result = dict(windows=windows, updated=now)
    cache.write_text(json.dumps(result, ensure_ascii=False))
    return result

def claude_usage(now=None, fresh=False):
    """Prefer the live account-wide report; fall back to the last statusLine record."""
    try: return claude_usage_live(now, fresh=fresh)
    except Exception as live_error:
        try: return claude_usage_recorded(now)
        except Exception: raise RuntimeError(query_error(live_error)) from None

def claude_usage_recorded(now=None):
    """Latest Claude subscription limits recorded by claude_statusline.py."""
    now = now or time.time()
    path = STATE / 'claude-usage.json'
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        raise RuntimeError('尚未取得 Claude 用量') from None
    except (OSError, ValueError):
        raise RuntimeError('Claude 額度紀錄無法讀取') from None
    limits = data.get('rate_limits') or {}
    names = {'five_hour': '5 小時', 'seven_day': '7 天'}
    windows = []
    for key, label in names.items():
        w = limits.get(key)
        # Claude Code drops a window once it resets; a stale record must too.
        if isinstance(w, dict) and isinstance(w.get('used_percentage'), (int, float)) and (w.get('resets_at') or now + 1) > now:
            windows.append(dict(id='claude-'+key, label=label, remaining=max(0, min(100, 100-w['used_percentage'])), resetsAt=w.get('resets_at'), plan=None))
    spend = limits.get('spend_limit')
    if isinstance(spend, dict) and isinstance(spend.get('used_percentage'), (int, float)) and (spend.get('resets_at') or now + 1) > now:
        period = {'daily': '每日', 'weekly': '每週', 'monthly': '每月'}.get(spend.get('period'), '')
        windows.append(dict(id='claude-spend', label=('花費上限 ' + period).strip(), remaining=max(0, min(100, 100-spend['used_percentage'])), resetsAt=spend.get('resets_at'), plan=None))
    return dict(windows=windows, updated=data.get('updated') or now)

def provider(id, label, read):
    try:
        result = read()
        return dict(id=id, label=label, windows=result['windows'], updated=result['updated'], error=None)
    except Exception as e:
        return dict(id=id, label=label, windows=[], updated=time.time(), error=query_error(e))

def quota(fresh=False):
    return dict(providers=[provider('codex', 'Codex', codex_quota), provider('claude', 'Claude', lambda: claude_usage(fresh=fresh))], updated=time.time())

if __name__=='__main__':
    try:
        if len(sys.argv)>1 and sys.argv[1]=='stream':
            stream_inventory()
            sys.exit(0)
        elif len(sys.argv)>1 and sys.argv[1]=='quota':
            result=quota(fresh=len(sys.argv)>2 and sys.argv[2]=='fresh')
        elif len(sys.argv)>2 and sys.argv[1] in ('launch-tab', 'launch-agent', 'focus-tab'):
            try:
                if sys.argv[1]=='launch-tab': result=launch_tab(sys.argv[2], sys.argv[3:])
                elif sys.argv[1]=='launch-agent':
                    rest = sys.argv[4:]
                    prompt = rest[1] if len(rest) > 1 and rest[0] == '--prompt' else None
                    result=launch_agent(sys.argv[2], sys.argv[3], rest[2:] if prompt is not None else rest, prompt=prompt)
                else: result=dict(tab=focus_tab(sys.argv[2]))
            except Exception as e: result=dict(error=query_error(e))
        elif len(sys.argv)>1 and sys.argv[1]=='focus':
            try: result=dict(agent=focus(sys.argv[2],sys.argv[3],sys.argv[4]))
            except Exception as e: result=dict(error=query_error(e))
        else: result=inventory()
        print(json.dumps(result, ensure_ascii=False))
    except Exception as e:
        if len(sys.argv)>1 and sys.argv[1]=='stream':
            print(json.dumps(dict(type='done', errors=[query_error(e)], updated=time.time()), ensure_ascii=False), flush=True)
        else:
            print(json.dumps(dict(agents=[],errors=[str(e)], updated=time.time())))

import importlib.util
from pathlib import Path
import unittest
import os, tempfile, subprocess, shlex, base64, json, threading
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('monitor',Path(__file__).parents[1]/'Resources/monitor.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def snapshot(agents):
    return {'result': {'snapshot': {'agents': agents,
        'workspaces': [{'workspace_id': 'w1'}],
        'tabs': [{'workspace_id': 'w1', 'tab_id': 'w1:t1'}],
        'panes': [{'tab_id': 'w1:t1', 'pane_id': a['pane_id']} for a in agents]}}}

class InventoryTests(unittest.TestCase):
    def test_sessions_are_namespaced_and_other_agent_kinds_ignored(self):
        def call(args):
            if args[0]=='machine': return []
            if args[0]=='session': return {'sessions':[{'name':'a','running':True},{'name':'b','running':True},{'name':'stopped','running':False}]}
            return snapshot([{'agent':'codex','pane_id':'w1:p1','agent_status':'blocked'},{'agent':'claude','pane_id':'w1:p2'},{'agent':'gemini','pane_id':'w1:p3'}])
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual([a['id'] for a in result['agents']],['local:a:w1:p1','local:a:w1:p2','local:b:w1:p1','local:b:w1:p2'])
        self.assertEqual([a['agent'] for a in result['agents']],['codex','claude','codex','claude'])
        self.assertEqual(result['agents'][0]['status'],'blocked')
    def test_failed_session_preserves_others_and_reports_error(self):
        def call(args):
            if args[0]=='machine': return []
            if args[0]=='session': return {'sessions':[{'name':'a','running':True},{'name':'b','running':True}]}
            if args[1]=='a': raise RuntimeError('offline')
            return snapshot([{'agent':'codex','pane_id':'w2:p1'}])
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual(len(result['agents']),1)
        self.assertEqual(result['agents'][0]['status'],'unknown')
        self.assertEqual(result['errors'],['Local/a: offline'])
    def test_remote_ids_do_not_collide_and_disabled_machines_are_ignored(self):
        def call(args):
            if args[0]=='session': return {'sessions':[{'name':'default','running':True}]}
            if args[0]=='machine': return [
                {'id':'lab','label':'lab_pc','session':'default','enabled':True},
                {'id':'sean','label':'sean_pc','session':'normal','enabled':True},
                {'id':'disabled','label':'old','enabled':False}]
            return snapshot([{'agent':'codex','pane_id':'w1:p1','agent_status':'working'}])
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual(len({a['id'] for a in result['agents']}),3)
        self.assertEqual([a['machine'] for a in result['agents']],['Local','lab_pc','sean_pc'])
        self.assertEqual([a['session'] for a in result['agents']],['default','default','normal'])
        self.assertEqual([x['agentCount'] for x in result['machines']],[1,1,1])
        self.assertEqual(result['navigation'], {'local:default:w1:p1':0, 'lab:default:w1:p1':3, 'sean:normal:w1:p1':6})
    def test_offline_remote_does_not_hide_local_or_other_remote(self):
        def call(args):
            if args[0]=='session': return {'sessions':[{'name':'default','running':True}]}
            if args[0]=='machine': return [{'id':x,'label':x,'enabled':True} for x in ['lab','sean']]
            if args[:2]==['--machine','lab']: raise RuntimeError('SSH timeout')
            return snapshot([{'agent':'codex','pane_id':'w1:p1'}])
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual([a['machine'] for a in result['agents']],['Local','sean'])
        self.assertEqual(result['navigation'], {'local:default:w1:p1':0})
        self.assertEqual(result['machines'][1]['state'],'offline')
        self.assertEqual(result['machines'][2]['state'],'online')
        self.assertEqual(result['errors'],['lab/default: SSH timeout'])
    def test_last_remote_timeout_preserves_earlier_navigation(self):
        def call(args):
            if args[0]=='session': return {'sessions':[{'name':'default','running':True}]}
            if args[0]=='machine': return [{'id':x,'label':x,'enabled':True} for x in ['lab','sean']]
            if args[:2]==['--machine','sean']: raise m.QueryTimeout('狀態讀取逾時，請稍後重試')
            return snapshot([{'agent':'codex','pane_id':'w1:p1'}])
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual(result['navigation'], {'local:default:w1:p1':0, 'lab:default:w1:p1':3})
        self.assertNotIn('sean:default:w1:p1',result['navigation'])
        self.assertEqual(result['errors'], ['sean/default: 狀態讀取逾時，請稍後重試'])
    def test_missing_local_snapshot_blocks_remote_positions(self):
        def call(args):
            if args[0]=='session': return {'sessions':[]}
            if args[0]=='machine': return [{'id':'lab','label':'lab','enabled':True}]
            return snapshot([{'agent':'codex','pane_id':'w1:p1'}])
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual(result['navigation'], {})
        self.assertEqual(len(result['agents']),1)
    def test_focus_uses_herdr_agent_focus_on_the_target_server(self):
        calls=[]
        def call(args):
            calls.append(args)
            if args[0] == 'machine':
                return [{'id':'lab','session':'default','enabled':True}, {'id':'sean','session':'normal','enabled':True}]
            return {'result':{'agent':{'pane_id':args[-1],'workspace_id':'w1'}}}
        with patch.object(m,'call',side_effect=call):
            self.assertEqual(m.focus('local','default','w1:p1')['pane_id'], 'w1:p1')
            self.assertEqual(m.focus('sean','normal','w2:p3')['pane_id'], 'w2:p3')
        self.assertEqual(calls, [['agent','focus','w1:p1'], ['machine','list','--json'], ['--machine','sean','agent','focus','w2:p3']])
    def test_focus_refuses_non_default_local_session(self):
        with patch.object(m,'call') as call:
            with self.assertRaises(RuntimeError): m.focus('local','work','w5:p1')
        call.assert_not_called()
    def test_changed_remote_session_refuses_stale_focus(self):
        with patch.object(m,'call',return_value=[{'id':'sean','session':'other','enabled':True}]) as call:
            with self.assertRaises(RuntimeError): m.focus('sean','normal','w1:p1')
        self.assertEqual(call.call_count,1)
    def test_herdr_json_error_message_is_reported(self):
        with self.assertRaisesRegex(RuntimeError, '^agent target w9:p9 not found$'):
            m.run_json(['sh','-c','echo \'{"error":{"code":"agent_not_found","message":"agent target w9:p9 not found"}}\' >&2; exit 1'], 5)
    def test_agents_carry_workspace_labels(self):
        def call(args):
            if args[0]=='session': return {'sessions':[{'name':'default','running':True}]}
            if args[0]=='machine': return []
            return {'result':{'snapshot':{'agents':[{'agent':'codex','pane_id':'w1:p1','workspace_id':'w1','state_change_seq':7,'focused':True}],
                'workspaces':[{'workspace_id':'w1','label':'~'}], 'tabs':[], 'panes':[]}}}
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual(result['agents'][0]['workspace'], '~')
        self.assertEqual((result['agents'][0]['activity'], result['agents'][0]['focused']), (7, True))
        self.assertEqual(result['machines'][0]['workspaces'], ['~'])
class WindowsSnapshotTests(unittest.TestCase):
    def test_direct_snapshot_keeps_target_session_and_quotes_executable(self):
        profile = {'id':'a'*32, 'target':'sean_pc', 'session':'normal'}
        metadata = {'os':'windows', 'executable':"C:\\Users\\O'Brien\\herdr.exe"}
        result = snapshot([])
        with patch.object(m,'windows_metadata',return_value=metadata), patch.object(m,'run_json',return_value=result) as run, patch.object(m,'call') as call:
            self.assertEqual(m.read_snapshot(['--machine',profile['id']],profile),result['result']['snapshot'])
        call.assert_not_called()
        command, timeout = run.call_args.args
        self.assertEqual(command[command.index('--')+1], 'sean_pc')
        script = base64.b64decode(command[-1].split()[-1]).decode('utf-16le')
        self.assertIn("& 'C:\\Users\\O''Brien\\herdr.exe' --session 'normal' 'api' 'snapshot'",script)
        self.assertNotIn('Start-Process',script)
        self.assertEqual(timeout,15)
    def test_stale_windows_metadata_is_rejected(self):
        profile = {'id':'a'*32, 'target':'sean_pc', 'session':'normal'}
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ,{'XDG_STATE_HOME':folder}):
            file = Path(folder)/'herdr/client/ssh-metadata'/('a'*32+'.json')
            file.parent.mkdir(parents=True)
            metadata = {'version':1,'target':'sean_pc','session':'normal','metadata':{'os':'windows','executable':r'C:\herdr.exe'}}
            file.write_text(json.dumps(metadata))
            self.assertEqual(m.windows_metadata(profile),metadata['metadata'])
            metadata['session']='default'
            file.write_text(json.dumps(metadata))
            self.assertIsNone(m.windows_metadata(profile))
    def test_missing_metadata_uses_standard_saved_machine_route(self):
        profile = {'id':'lab','target':'lab_pc','session':'default'}
        result=snapshot([])
        with patch.object(m,'windows_metadata',return_value=None),patch.object(m,'call',return_value=result) as call,patch.object(m,'run_json') as run:
            m.read_snapshot(['--machine','lab'],profile)
        self.assertEqual(call.call_args.args[0],['--machine','lab','api','snapshot'])
        run.assert_not_called()

class StreamingInventoryTests(unittest.TestCase):
    def test_online_remote_is_emitted_before_an_earlier_blocked_remote(self):
        lab_started = threading.Event()
        sean_emitted = threading.Event()
        events = []
        def call(args):
            if args[0] == 'session':
                return {'sessions': [{'name': 'default', 'running': True}]}
            if args[0] == 'machine':
                return [{'id': name, 'label': name + '_pc', 'enabled': True} for name in ['lab', 'sean']]
            if args[:2] == ['--machine', 'lab']:
                lab_started.set()
                if not sean_emitted.wait(timeout=2):
                    raise AssertionError('Healthy endpoint was held behind the blocked endpoint')
                raise RuntimeError('SSH offline')
            if args[:2] == ['--machine', 'sean']:
                self.assertTrue(lab_started.wait(timeout=2))
            return snapshot([{'agent': 'codex', 'pane_id': 'w1:p1'}])
        def emit(event):
            events.append(event)
            if event['type'] == 'target' and event['machineId'] == 'sean':
                sean_emitted.set()
        with patch.object(m, 'call', side_effect=call):
            result = m.inventory(emit=emit)
        self.assertEqual(events[0]['type'], 'targets')
        self.assertEqual([machine['state'] for machine in events[0]['machines']], ['checking'] * 3)
        self.assertEqual(events[0]['targets'], [{'machineId': name, 'session': 'default'} for name in ['local', 'lab', 'sean']])
        completed = [event for event in events if event['type'] == 'target']
        self.assertLess(next(i for i, event in enumerate(completed) if event['machineId'] == 'sean'),
            next(i for i, event in enumerate(completed) if event['machineId'] == 'lab'))
        sean = next(event for event in completed if event['machineId'] == 'sean')
        lab = next(event for event in completed if event['machineId'] == 'lab')
        self.assertEqual((sean['state'], sean['error'], len(sean['agents'])), ('online', None, 1))
        self.assertEqual((lab['state'], lab['error'], lab['agents']), ('offline', 'lab_pc/default: SSH offline', []))
        self.assertEqual(events[-1]['type'], 'done')
        self.assertEqual([agent['machineId'] for agent in result['agents']], ['local', 'sean'])
        self.assertEqual(events[-1]['agents'], result['agents'])
        self.assertEqual(events[-1]['errors'], ['lab_pc/default: SSH offline'])

    def test_stream_lines_are_flushed_and_have_completion_event(self):
        events = [{'type': 'targets'}, {'type': 'target', 'machineId': 'sean'}, {'type': 'done'}]
        def inventory(emit):
            for event in events:
                emit(event)
        with patch.object(m, 'inventory', side_effect=inventory), patch('builtins.print') as output:
            m.stream_inventory()
        self.assertEqual([json.loads(call.args[0]) for call in output.call_args_list], events)
        self.assertTrue(all(call.kwargs['flush'] for call in output.call_args_list))

    def test_discovery_failure_has_no_stuck_checking_machine(self):
        def call(args):
            if args[0] == 'session':
                raise RuntimeError('local unavailable')
            if args[0] == 'machine':
                return []
            self.fail('No snapshot should be requested when no target was discovered')
        events = []
        with patch.object(m, 'call', side_effect=call):
            result = m.inventory(emit=events.append)
        self.assertEqual([event['type'] for event in events], ['targets', 'done'])
        self.assertEqual(events[0]['machines'][0]['state'], 'offline')
        self.assertEqual(events[0]['targets'], [])
        self.assertEqual(result['errors'], ['Local: local unavailable'])

class QueryTimeoutTests(unittest.TestCase):
    def test_timeout_stops_query_child_and_hides_command(self):
        with tempfile.TemporaryDirectory() as folder:
            child_file = Path(folder)/'child.pid'
            command = 'sleep 30 & child=$!; printf "%s" "$child" > '+shlex.quote(str(child_file))+'; wait'
            with patch.object(m,'binary',return_value='/bin/sh'):
                with self.assertRaises(m.QueryTimeout) as error:
                    m.call(['-c', command], timeout=.5)
            self.assertNotIn(command,str(error.exception))
            child_pid = int(child_file.read_text())
            state = subprocess.run(['ps','-o','stat=','-p',str(child_pid)], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'), f'query child still running: {state}')

if __name__=='__main__': unittest.main()


class ClaudeUsageTests(unittest.TestCase):
    def write(self, directory, data):
        Path(directory, 'claude-usage.json').write_text(json.dumps(data))
    def test_windows_are_remaining_percentages_and_expired_windows_dropped(self):
        with tempfile.TemporaryDirectory() as d, patch.object(m, 'STATE', Path(d)):
            self.write(d, {'updated': 50, 'rate_limits': {
                'five_hour': {'used_percentage': 23.5, 'resets_at': 90},
                'seven_day': {'used_percentage': 61, 'resets_at': 500},
                'spend_limit': {'used_percentage': 120, 'resets_at': 900, 'period': 'weekly'}}})
            result = m.claude_usage(now=100)
        self.assertEqual([(w['label'], w['remaining']) for w in result['windows']], [('7 天', 39), ('花費上限 每週', 0)])
        self.assertEqual(result['updated'], 50)
    def test_missing_record_explains_setup(self):
        with tempfile.TemporaryDirectory() as d, patch.object(m, 'STATE', Path(d)):
            with self.assertRaisesRegex(RuntimeError, 'statusLine'): m.claude_usage()
    def test_quota_reports_each_provider_independently(self):
        with patch.object(m, 'codex_quota', side_effect=RuntimeError('Codex server exited')), \
             patch.object(m, 'claude_usage', return_value={'windows': [], 'updated': 7}):
            result = m.quota()
        self.assertEqual([(p['id'], p['error']) for p in result['providers']], [('codex', 'Codex server exited'), ('claude', None)])

class StatuslineWrapperTests(unittest.TestCase):
    script = str(Path(__file__).parents[1] / 'Resources/claude_statusline.py')
    def run_wrapper(self, state, payload, *args):
        return subprocess.run(['python3', self.script, *args], input=payload, capture_output=True, text=True,
                              env=dict(os.environ, HERDR_NOTCH_STATE=state))
    def test_records_limits_and_passes_identical_input_to_wrapped_command(self):
        payload = json.dumps({'model': {'display_name': 'Opus'}, 'rate_limits': {'five_hour': {'used_percentage': 5, 'resets_at': 9}}})
        with tempfile.TemporaryDirectory() as d:
            result = self.run_wrapper(d, payload, '--wrap', 'cat; exit 3')
            self.assertEqual((result.stdout, result.returncode), (payload, 3))
            self.assertEqual(json.loads(Path(d, 'claude-usage.json').read_text())['rate_limits']['five_hour']['used_percentage'], 5)
    def test_without_limits_or_wrapped_command_prints_fallback_and_records_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.run_wrapper(d, json.dumps({'model': {'display_name': 'Opus'}, 'context_window': {'used_percentage': 41.6}}))
            self.assertEqual(result.stdout.strip(), '[Opus] context 42%')
            self.assertFalse(Path(d, 'claude-usage.json').exists())
    def test_invalid_input_still_runs_status_line(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.run_wrapper(d, 'not json', '--wrap', 'echo ok').stdout, 'ok\n')

class LaunchTests(unittest.TestCase):
    def test_paths_are_shell_escaped_inside_one_bracketed_paste(self):
        self.assertEqual(m.pasted_paths(['/a/My File (1).md', '/tmp/圖.png']),
                         '\x1b[200~/a/My\\ File\\ \\(1\\).md /tmp/圖.png \x1b[201~')
    def test_tab_opens_focused_in_the_dropped_files_repository(self):
        calls = []
        def call(args, timeout=None):
            calls.append(args)
            if args[0] == 'tab': return {'result': {'tab': {'tab_id': 'w1:t2', 'workspace_id': 'w1'}, 'root_pane': {'pane_id': 'w1:p3'}}}
            return {'result': {'workspace': {'label': 'shop'}}}
        with tempfile.TemporaryDirectory() as d, patch.object(m, 'call', side_effect=call), patch.object(m, 'launch_cwd', return_value='/repo'):
            path = os.path.join(d, 'note.md'); Path(path).write_text('x')
            result = m.launch_tab('claude', [path])
        self.assertEqual(calls[0], ['tab', 'create', '--cwd', '/repo', '--label', 'note.md', '--focus'])
        self.assertEqual(result, {'pane': 'w1:p3', 'tab': 'w1:t2', 'workspace': 'shop', 'cwd': '/repo', 'label': 'note.md'})
    def test_bad_kind_or_missing_file_never_reaches_herdr(self):
        with patch.object(m, 'call') as call:
            with self.assertRaises(RuntimeError): m.launch_tab('gemini', ['/tmp'])
            with self.assertRaises(RuntimeError): m.launch_tab('codex', ['/nonexistent/file'])
            with self.assertRaises(RuntimeError): m.launch_tab('codex', [])
        call.assert_not_called()
    def run_agent(self, visible, start_error=None):
        calls, copied = [], []
        def call(args, timeout=None):
            calls.append(args)
            if args[:2] == ['agent', 'start'] and start_error: raise RuntimeError(start_error)
            return {'result': {}}
        def run(command, **kwargs):
            if command[0] == 'pbcopy': copied.append(kwargs['input'])
            return subprocess.CompletedProcess(command, 0, stdout=visible, stderr='')
        with patch.object(m, 'call', side_effect=call), patch.object(m.subprocess, 'run', side_effect=run), patch.object(m.time, 'sleep'):
            result = m.launch_agent('codex', 'w1:p3', ['/repo/My Notes.md'])
        return result, calls, copied
    def test_paste_confirmed_on_screen_leaves_the_clipboard_alone(self):
        result, calls, copied = self.run_agent('› /repo/My\\ Notes.md \n')
        self.assertEqual((result['pasted'], result['copied'], copied), (True, False, []))
        self.assertEqual([c[:2] for c in calls], [['agent', 'start'], ['agent', 'focus'], ['pane', 'send-text']])
        self.assertTrue(calls[2][3].startswith('\x1b[200~') and calls[2][3].endswith('\x1b[201~'))
    def test_paste_swallowed_by_a_startup_dialog_falls_back_to_the_clipboard(self):
        result, _, copied = self.run_agent('Trust this folder?\n› 1. Trust and continue\n', start_error='timed out waiting for agent startup')
        self.assertEqual((result['pasted'], result['copied'], result['startError']), (False, True, 'timed out waiting for agent startup'))
        self.assertEqual(copied, ['/repo/My\\ Notes.md '])
    def test_folders_and_any_file_type_are_handed_over_as_paths(self):
        calls = []
        def call(args, timeout=None):
            calls.append(args)
            if args[0] == 'tab': return {'result': {'tab': {'tab_id': 'w1:t2', 'workspace_id': 'w1'}, 'root_pane': {'pane_id': 'w1:p3'}}}
            return {'result': {'workspace': {'label': '~'}}}
        with tempfile.TemporaryDirectory() as d, patch.object(m, 'call', side_effect=call):
            folder = os.path.join(d, 'My Project'); os.mkdir(folder)
            archive = os.path.join(d, 'data.zip'); Path(archive).write_bytes(b'PK\x03\x04')
            # A dropped folder is the working directory itself; a file uses its parent.
            self.assertEqual(os.path.realpath(m.launch_tab('codex', [folder])['cwd']), os.path.realpath(folder))
            self.assertEqual(calls[0][calls[0].index('--label') + 1], 'My Project')
            self.assertEqual(os.path.realpath(m.launch_tab('claude', [archive, folder])['cwd']), os.path.realpath(d))
            self.assertEqual(m.pasted_paths([archive, folder]), '\x1b[200~' + archive + ' ' + folder.replace(' ', '\\ ') + ' \x1b[201~')

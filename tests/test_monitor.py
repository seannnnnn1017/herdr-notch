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
    def test_sessions_are_namespaced_and_non_codex_ignored(self):
        def call(args):
            if args[0]=='machine': return []
            if args[0]=='session': return {'sessions':[{'name':'a','running':True},{'name':'b','running':True},{'name':'stopped','running':False}]}
            return snapshot([{'agent':'codex','pane_id':'w1:p1','agent_status':'blocked'},{'agent':'claude','pane_id':'w1:p2'}])
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual([a['id'] for a in result['agents']],['local:a:w1:p1','local:b:w1:p1'])
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
            return {'result':{'snapshot':{'agents':[{'agent':'codex','pane_id':'w1:p1','workspace_id':'w1'}],
                'workspaces':[{'workspace_id':'w1','label':'~'}], 'tabs':[], 'panes':[]}}}
        with patch.object(m,'call',side_effect=call): result=m.inventory()
        self.assertEqual(result['agents'][0]['workspace'], '~')
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

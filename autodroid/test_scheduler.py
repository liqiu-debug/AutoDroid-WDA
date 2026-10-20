"""Exercise installed WDA using harmless changing scripts; never contact Feishu."""
import json, time, urllib.request, threading, uuid, os
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
WDA=os.environ.get('TEST_WDA_URL','http://127.0.0.1:8100')
HOST=os.environ.get('TEST_BUNDLE_URL','http://127.0.0.1:18081')
op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
revision=0
def bundle(marker, delay=0):
    return dict(format_version=1,manifest=dict(platform='ios',kind='case'),precheck=dict(ok=True),runtime_js='// fixture',adapter_js='// fixture',case_files={},main_js=f'var end=Date.now()+{delay}; while(Date.now()<end){{}}; globalThis.__AUTODROID_RESULT__={{success:true,marker:{marker}}};')
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        global revision
        assert self.headers.get('Authorization')=='Bearer local-test-only'
        if self.path=='/slow': time.sleep(3)
        if self.path=='/unauthorized': status=401; payload=dict(detail='expired')
        else:
            revision+=1; status=200; payload=bundle(revision)
            if self.path=='/invalid': payload['precheck']['ok']=False
        data=json.dumps(payload).encode(); self.send_response(status); self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(data)
def request(path, body=None):
    req=urllib.request.Request(WDA+'/autodroid/'+path,data=None if body is None else json.dumps(body).encode(),headers={'Content-Type':'application/json'})
    return json.load(op.open(req,timeout=15))['value']
def task(path='/script', rule='once'):
    return dict(id=str(uuid.uuid4()),name='定时链路自检',rule=rule,next_run=time.time()+1,hour=9,minute=0,weekday=2,interval=60,timezone='Asia/Shanghai',server=HOST,username='scheduler-test',fetch_url=HOST+path,token='local-test-only',notify=False,system_notify=False,device_serial='scheduler-test')
def wait_event(identifier, timeout=20):
    until=time.time()+timeout
    while time.time()<until:
        state=request('schedules')
        new=[e for e in state['events'] if e['run_id'] not in identifier and e['username']=='scheduler-test']
        if new and new[-1]['finished']: return new[-1],state
        time.sleep(.3)
    raise AssertionError('event timed out')
def existing(): return {e['run_id'] for e in request('schedules')['events']}
server=ThreadingHTTPServer(('0.0.0.0',18081),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
assert request('schedules')['items']==[], 'User schedules exist; refusing to replace'
assert not request('status')['running'], 'Executor busy'
try:
    markers=[]
    for _ in range(2):
        before=existing(); spec=task();request('schedules',{'items':[spec]})
        event,state=wait_event(before)
        assert event['result'].get('success') is True,event
        markers.append(event['result']['marker'])
        assert state['items'][0]['enabled'] is False
        count=len(state['events']);time.sleep(2)
        assert len(request('schedules')['events'])==count,'Duplicate once run'
    assert markers[1]>markers[0]
    print('PASS: two executions fetched distinct fresh bundles; once jobs did not repeat',flush=True)
    before=existing();request('schedules',{'items':[task('/invalid')]})
    event,_=wait_event(before);assert event['result']['script_fetch_failed'] is True
    print('PASS: failed precheck never executed',flush=True)
    before=existing();request('schedules',{'items':[task('/slow')]})
    until=time.time()+10
    while len(existing())==len(before) and time.time()<until: time.sleep(.1)
    request('schedules',{'items':[]})
    event,_=wait_event(before);assert '取消' in event['result']['error']
    print('PASS: cancellation during fetch never executed',flush=True)
    before=existing();request('run',{'bundle':bundle(999,4000),'run_id':str(uuid.uuid4()),'notify':False,'system_notify':False})
    request('schedules',{'items':[task()]});time.sleep(2)
    assert existing()==before,'Scheduled task overlapped running task'
    event,_=wait_event(before);assert event['result']['success'] is True
    print('PASS: busy executor deferred scheduled execution',flush=True)
    before=existing();request('schedules',{'items':[task('/unauthorized','interval')]})
    event,state=wait_event(before);assert state['items'][0]['enabled'] is False
    assert 'token' not in json.dumps(state),'Token leaked into status'
    print('PASS: expired session disabled recurring jobs; status excluded token',flush=True)
finally:
    request('schedules',{'items':[]});server.shutdown()

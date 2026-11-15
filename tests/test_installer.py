"""PTY bootstrap tests with a local fake curl and harmless payload. No installation/network."""
from pathlib import Path
import os,pty,tempfile,hashlib,json,shlex,select,time
INSTALLER=Path(__file__).resolve().parents[1] / 'install-vps-fw.sh';results=[]
with tempfile.TemporaryDirectory(prefix='fw-bootstrap-') as td:
 d=Path(td);binpath=d/'bin';binpath.mkdir();tmp=d/'tmp';tmp.mkdir()
 payload=d/'payload';payload.write_text('#!/bin/bash\nprintf "VERIFIED_PAYLOAD_EXECUTED\\n"\n')
 for n,body in {'id':'#!/bin/sh\necho 0\n','sha256sum':'#!/usr/bin/env python3\nimport hashlib,sys\np=sys.argv[1];print(hashlib.sha256(open(p,"rb").read()).hexdigest()+"  "+p)\n','curl':'#!/bin/bash\n[[ "${MOCK_FAIL:-0}" == 0 ]] || exit 22\nwhile (( $# )); do if [[ "$1" == -o ]]; then shift; cp "$MOCK_PAYLOAD" "$1"; exit $?; fi; shift; done\nexit 1\n'}.items():
  p=binpath/n;p.write_text(body);p.chmod(0o755)
 def case(name,url,expectedhash,executed,mode='pipe',fail='0'):
  env={**os.environ,'PATH':str(binpath)+':'+os.environ['PATH'],'MOCK_PAYLOAD':str(payload),'MOCK_FAIL':fail,'TMPDIR':str(tmp)}
  args=' '.join(map(shlex.quote,[url,expectedhash]))
  command=('cat '+shlex.quote(str(INSTALLER))+' | bash -s -- '+args) if mode=='pipe' else ('bash '+shlex.quote(str(INSTALLER))+' '+args)
  pid,fd=pty.fork()
  if pid==0:os.execve('/bin/bash',['bash','-c',command],env)
  out=b'';end=time.monotonic()+10
  while time.monotonic()<end:
   if select.select([fd],[],[],.2)[0]:
    try:b=os.read(fd,65536)
    except OSError:break
    if not b:break
    out+=b
  _,status=os.waitpid(pid,0);os.close(fd)
  code=os.waitstatus_to_exitcode(status)
  actual=b'VERIFIED_PAYLOAD_EXECUTED' in out
  good=(actual==executed and (code==0)==executed and not list(tmp.iterdir()))
  r={'test':name,'exit':code,'pass':good};results.append(r);print(json.dumps(r))
 url='https://raw.githubusercontent.com/example/fw/'+'a'*40+'/vps-fw.sh'
 digest=hashlib.sha256(payload.read_bytes()).hexdigest()
 case('verified_pipe_executes_in_tty',url,digest,True)
 case('verified_local_installer_executes',url,digest,True,'local')
 case('wrong_hash_does_not_execute',url,'0'*64,False)
 case('mutable_branch_url_rejected',url.replace('a'*40,'main'),digest,False)
 case('failed_download_does_not_execute',url,digest,False,fail='1')
 payload.write_text('#!/bin/bash\nif\n')
 case('syntax_error_payload_does_not_execute',url,hashlib.sha256(payload.read_bytes()).hexdigest(),False)
Path(__file__).with_name('v3.1.0-installer-results.json').write_text(json.dumps(results,indent=2))
raise SystemExit(0 if all(r['pass'] for r in results) else 1)

"""Updater tests use local fake downloads and temporary installation targets only."""
import tempfile,subprocess as sp,hashlib
from pathlib import Path
SRC=Path(__file__).resolve().parents[1]/'vps-fw.sh'
with tempfile.TemporaryDirectory() as tmp:
 root=Path(tmp);lib=root/'lib';lib.write_text(SRC.read_text().rsplit('main "$@"',1)[0]);count=0
 def test(name,manifest=None,payload='#!/bin/bash\nVERSION="3.1.4"\n',setup='',answer='y\n',expected=1,installed=False):
  global count
  count+=1;d=root/str(count);d.mkdir();(d/'payload').write_text(payload)
  if manifest is None:manifest='VERSION=3.1.4\nCOMMIT='+'a'*40+'\nSHA256='+hashlib.sha256(payload.encode()).hexdigest()+'\n'
  (d/'manifest').write_text(manifest)
  code='''source "$1"; trap - EXIT
CONF_DIR="$2/conf"; DRAFT_DIR="$2/draft"; EXEC_PATH="$2/fw"; BIN_LINK="$2/bin/fw"; LOCK_FILE="$2/lock"
VERSION=3.1.3; check_draft_dirty(){ CHANGES_PENDING=0; }; with_lock(){ "$@"; }
fetch_update_file(){ case "$1" in */update.manifest) cp "$TEST_DIR/manifest" "$2";; */vps-fw.sh) cp "$TEST_DIR/payload" "$2";; *) return 1;; esac; }
TEST_DIR="$2"; mkdir -p "$CONF_DIR"; echo old > "$EXEC_PATH"
'''+setup+'\ncheck_and_install_update'
  r=sp.run(['bash','-c',code,'test',str(lib),str(d)],input=answer,text=True,errors="replace",capture_output=True,timeout=15)
  assert r.returncode==expected,(name,r.returncode,r.stdout,r.stderr)
  assert ((d/'fw').read_text()==payload if installed else (d/'fw').read_text()=='old\n'),name
  print('PASS',name)
 test('verified update',expected=10,installed=True)
 test('decline',answer='n\n',expected=0)
 test('download failure',setup='fetch_update_file(){ return 1; }')
 test('bad hash',manifest='VERSION=3.1.4\nCOMMIT='+'a'*40+'\nSHA256='+'0'*64+'\n')
 test('mutable commit',manifest='VERSION=3.1.4\nCOMMIT=main\nSHA256='+'0'*64+'\n')
 test('duplicate field',manifest='VERSION=3.1.4\nVERSION=3.1.5\n')
 test('unknown field',manifest='EVIL=$(touch /tmp/should-not-run)\n')
 test('bad syntax',payload='VERSION="3.1.4"\nif then\n')
 test('version mismatch',payload='VERSION="3.1.5"\n',manifest='VERSION=3.1.4\nCOMMIT='+'a'*40+'\nSHA256='+hashlib.sha256(b'VERSION="3.1.5"\n').hexdigest()+'\n')
 test('pending refuses',setup='touch "$CONF_DIR/pending.state"')
 test('dirty draft refuses',setup='check_draft_dirty(){ CHANGES_PENDING=1; }')
 test('fault refuses install',setup='touch "$CONF_DIR/fault.state"')
 test('same version',payload='VERSION="3.1.3"\n',manifest='VERSION=3.1.3\nCOMMIT='+'a'*40+'\nSHA256='+'0'*64+'\n',expected=0)
 test('older version',manifest='VERSION=3.1.2\nCOMMIT='+'a'*40+'\nSHA256='+'0'*64+'\n',expected=0)
 test('pending appears under lock',setup='with_lock(){ touch "$CONF_DIR/pending.state"; "$@"; }')
 test('demo never downloads',setup='DEMO_MODE=1; fetch_update_file(){ return 99; }',expected=0)

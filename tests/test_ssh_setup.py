"""SSH wizard and management tests; isolated drafts, no kernel changes."""
from pathlib import Path
import tempfile,subprocess as sp
src=Path(__file__).resolve().parents[1]/'vps-fw.sh'
with tempfile.TemporaryDirectory() as td:
 root=Path(td);lib=root/'lib';lib.write_text(src.read_text().rsplit('main "$@"',1)[0]);n=0
 def test(name,body,inputs='',want=0):
  global n
  n+=1;d=root/str(n);d.mkdir()
  pre='''source "$1"; trap - EXIT
CONF_DIR="$2/conf"; DRAFT_DIR="$2/draft"; DEMO_MODE=1; CFG_WAN_IF=eth0
clear_screen(){ :; }; pause_prompt(){ :; }; detect_wan_if(){ echo eth0; }; detect_ssh_port(){ echo 22; }; detect_ssh_client_ip(){ :; }
with_lock(){ echo UNEXPECTED_APPLY >&2; exit 99; }
save_conf "$DRAFT_DIR"; touch "$DRAFT_DIR/rules.db"
'''
  r=sp.run(['bash','-c',pre+body,'test',str(lib),str(d)],input=inputs,text=True,capture_output=True,timeout=10)
  assert r.returncode==want and 'UNEXPECTED_APPLY' not in r.stderr,(name,r.stdout,r.stderr,r.returncode)
  print('PASS',name)
 test('unknown source blank cancels','first_time_setup','22\n\n\n',1)
 test('unknown source rejects empty whitelist','first_time_setup','22\n\n1\n\n',1)
 test('explicit any requires confirmation','first_time_setup','22\n\n2\nn\n',1)
 test('explicit any accepted','first_time_setup && grep -q "|22|any|" "$DRAFT_DIR/rules.db"','22\n\n2\ny\n')
 test('explicit whitelist accepted','first_time_setup && load_conf "$DRAFT_DIR" && [[ "$CFG_SSH_MODE" == whitelist && "$CFG_SSH_SOURCES" == 192.0.2.9 ]]','22\n\n1\n192.0.2.9\n')
 test('known source still chooses','detect_ssh_client_ip(){ echo 192.0.2.8; }; first_time_setup && load_conf "$DRAFT_DIR" && [[ "$CFG_SSH_SOURCES" == 192.0.2.8 ]]','22\n\n1\n\n')
 setup='CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=192.0.2.8; save_conf "$DRAFT_DIR"; '
 test('SSH delete closes public SSH',setup+'action_manage_rules; load_conf "$DRAFT_DIR"; [[ "$CFG_SSH_MODE" == hidden && -z "$CFG_SSH_SOURCES" ]]','2\nSSH\n2\ny\n')
 test('SSH delete cancellation preserves',setup+'action_manage_rules; load_conf "$DRAFT_DIR"; [[ "$CFG_SSH_MODE" == whitelist ]]','2\nSSH\n2\nn\n')
 test('explicit cancel restriction',setup+'action_manage_rules; load_conf "$DRAFT_DIR"; [[ "$CFG_SSH_MODE" == none ]]','2\nSSH\n3\ny\n')
 test('modify SSH through menu 3',setup+'action_manage_rules; load_conf "$DRAFT_DIR"; [[ "$CFG_SSH_SOURCES" == 192.0.2.9 ]]','4\n1\n192.0.2.9\n')
 test('clear black list',setup+'CFG_SSH_BLOCK=192.0.2.10; save_conf "$DRAFT_DIR"; action_manage_rules; load_conf "$DRAFT_DIR"; [[ -z "$CFG_SSH_BLOCK" ]]','2\nSSH-B\n4\n\ny\n')
 test('mixed deletion rejected',setup+'printf "%s\\n" "1|1|accept|in|host|tcp|80|any|web" > "$DRAFT_DIR/rules.db"; action_manage_rules; grep -q "|80|" "$DRAFT_DIR/rules.db"','2\nSSH,1\n')
 test('off placeholder hidden','ui_policy_rows "$DRAFT_DIR" | grep -q SSH',want=1)

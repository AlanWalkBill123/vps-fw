"""Display-only regression: temporary files, no real firewall/systemd calls."""
import subprocess as sp, tempfile
from pathlib import Path
SRC=Path(__file__).resolve().parents[1]/'vps-fw.sh'
with tempfile.TemporaryDirectory() as tmp:
 d=Path(tmp);lib=d/'lib';lib.write_text(SRC.read_text().rsplit('main "$@"',1)[0])
 def run(body):
  code='source "$1"; trap - EXIT; CONF_DIR="$2/saved"; DRAFT_DIR="$2/draft"; CFG_WAN_IF=eth0; save_conf "$CONF_DIR"; save_conf "$DRAFT_DIR"; : > "$CONF_DIR/rules.db"; : > "$DRAFT_DIR/rules.db"; '+body
  r=sp.run(['bash','-c',code,'test',str(lib),str(d)],capture_output=True,text=True)
  assert r.returncode==0,r.stderr
  return r.stdout+r.stderr
 def check(name,body,yes=(),no=()):
  out=run(body)
  assert all(x in out for x in yes) and all(x not in out for x in no),(name,out)
  print('PASS',name)
 row='1|1|accept|in|host|tcp|3000|192.0.2.1|panel'
 check('SSH without ordinary rows','CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=192.0.2.7; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"',('SSH','入站白名单','192.0.2.7'),('所有公网入站和 Docker',))
 check('hidden SSH','CFG_SSH_MODE=hidden; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"',('SSH','入站拒绝','公网隐身'))
 check('deleted row details',f'printf %s "{row}" > "$CONF_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('待删除','3000','192.0.2.1','panel'))
 check('multiple additions','printf "%s\\n" "'+row+'" "2|1|accept|in|host|tcp|443|any|web" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('待新增','#1','#2'))
 check('changed row',f'printf %s "{row}" > "$CONF_DIR/rules.db"; printf %s "{row.replace("3000","3001")}" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('修改前','待修改','3000','3001'))
 check('unchanged',f'printf %s "{row}" > "$CONF_DIR/rules.db"; cp "$CONF_DIR/rules.db" "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',no=('待新增','待删除','待修改'))
 check('order changes','printf "%s\\n" "1|1|accept|in|host|tcp|22|any|a" "2|1|drop|in|host|tcp|22|any|b" > "$CONF_DIR/rules.db"; sed -n "2p;1p" "$CONF_DIR/rules.db" > /dev/null; awk \'{a[NR]=$0} END {print a[2];print a[1]}\' "$CONF_DIR/rules.db" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('待排序','#2','#1'))
 check('SSH config changes','CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=192.0.2.8; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"',('待修改','192.0.2.8'))
 check('pending confirmed distinction', 'mkdir -p "$CONF_DIR"; touch "$CONF_DIR/pending.state"; render_rules_table "$DRAFT_DIR"', ('待确认',))
 check('long IPv6 preserved', 'CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=2001:db8:1234:5678:abcd:ef01:2345:6789; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"', ('2001:db8:1234:5678:abc', 'd:ef01:2345:6789'))
 # Mock external effects; only the message severity should differ.
 mocks='nft(){ cat >/dev/null; }; logger(){ :; }; systemctl(){ return 1; }; sync(){ :; }; '
 check('normal transaction info',mocks+'quarantine_locked "应用事务进行中" 1',('[INFO]','临时隔离'),('[ERR]',))
 check('real fault still error',mocks+'quarantine_locked "测试故障"',('[ERR]','请通过 VNC 恢复'))

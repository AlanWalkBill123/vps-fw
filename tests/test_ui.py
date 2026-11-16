"""Display-only regression: temporary files, no real firewall/systemd calls."""
import subprocess as sp, tempfile
from pathlib import Path
SRC=Path(__file__).resolve().parents[1]/'vps-fw.sh'
with tempfile.TemporaryDirectory() as tmp:
 d=Path(tmp);case_number=0;lib=d/'lib';lib.write_text(SRC.read_text().rsplit('main "$@"',1)[0])
 def run(body):
  global case_number
  case_number+=1;case_dir=d/str(case_number);case_dir.mkdir()
  code='source "$1"; trap - EXIT; CONF_DIR="$2/saved"; DRAFT_DIR="$2/draft"; CFG_WAN_IF=eth0; save_conf "$CONF_DIR"; save_conf "$DRAFT_DIR"; : > "$CONF_DIR/rules.db"; : > "$DRAFT_DIR/rules.db"; '+body
  r=sp.run(['bash','-c',code,'test',str(lib),str(case_dir)],capture_output=True,text=True,timeout=15)
  assert r.returncode==0,r.stderr
  return r.stdout+r.stderr
 def check(name,body,yes=(),no=()):
  out=run(body)
  assert all(x in out for x in yes) and all(x not in out for x in no),(name,out)
  print('PASS',name)
 row='1|1|accept|in|host|tcp|3000|192.0.2.1|panel'
 check('SSH without ordinary rows','CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=192.0.2.7; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"',('SSH','入站','允许','192.0.2.7','SSH白名单'),('所有公网入站和 Docker',))
 check('hidden SSH','CFG_SSH_MODE=hidden; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"',('SSH','入站','拒绝','SSH公网关闭'))
 check('deleted row details',f'printf %s "{row}" > "$CONF_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('待删除','3000','192.0.2.1','panel'))
 check('multiple additions','printf "%s\\n" "'+row+'" "2|1|accept|in|host|tcp|443|any|web" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('待新增','#1','#2'))
 check('changed row',f'printf %s "{row}" > "$CONF_DIR/rules.db"; printf %s "{row.replace("3000","3001")}" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('修改前','待修改','3000','3001'))
 check('unchanged',f'printf %s "{row}" > "$CONF_DIR/rules.db"; cp "$CONF_DIR/rules.db" "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',no=('待新增','待删除','待修改'))
 check('order changes','printf "%s\\n" "1|1|accept|in|host|tcp|22|any|a" "2|1|drop|in|host|tcp|22|any|b" > "$CONF_DIR/rules.db"; sed -n "2p;1p" "$CONF_DIR/rules.db" > /dev/null; awk \'{a[NR]=$0} END {print a[2];print a[1]}\' "$CONF_DIR/rules.db" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('待排序','#2','#1'))
 check('SSH config changes','CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=192.0.2.8; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"',('待新增','192.0.2.8'))
 check('pending confirmed distinction', 'mkdir -p "$CONF_DIR"; touch "$CONF_DIR/pending.state"; CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=192.0.2.9; save_conf "$CONF_DIR"; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"', ('待确认',))
 check('long IPv6 preserved', 'CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=2001:db8:1234:5678:abcd:ef01:2345:6789; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"', ('2001:db8:1234:5678', ':abcd:ef01:2345:67', '89'))
 # The table contains rule rows only, and each field has one vocabulary.
 out=run('render_rules_table "$DRAFT_DIR"')
 assert '方向 动作' in out and '变更' not in out and '方向/策略' not in out
 assert '在 [4] 管理' not in out and '已保存' not in out
 print('PASS consistent headers and no prose footer')
 check('enabled saved row',f'printf %s "{row}" > "$CONF_DIR/rules.db"; cp "$CONF_DIR/rules.db" "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('启用',),('待新增','待修改','待确认','已保存'))
 check('disabled saved row',f'printf %s "{row.replace("1|1|", "1|0|",1)}" > "$CONF_DIR/rules.db"; cp "$CONF_DIR/rules.db" "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('停用',),('待新增','待修改'))
 for old,new,label in [(1,0,'待停用'),(0,1,'待启用')]:
  check(label,f'printf %s "{row.replace("1|1|",f"1|{old}|",1)}" > "$CONF_DIR/rules.db"; printf %s "{row.replace("1|1|",f"1|{new}|",1)}" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',(label,'修改前/'),('待修改',))
 check('disabled addition',f'printf %s "{row.replace("1|1|","1|0|",1)}" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('待新增/停用',))
 check('outbound deny terminology','printf "%s\\n" "1|1|drop|out|all|any|any|any|deny" > "$DRAFT_DIR/rules.db"; render_rules_table "$DRAFT_DIR"',('出站','拒绝','全部','任意地址(双栈)'),('ANY','DROP'))
 # Ensure all table lines share the same terminal width, including CJK and wrapped IPv6.
 import unicodedata
 def width(text):
  return sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in text)
 out=run('CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=2001:db8:1234:5678:abcd:ef01:2345:6789; save_conf "$DRAFT_DIR"; render_rules_table "$DRAFT_DIR"')
 lines=out.splitlines();assert len({width(l) for l in lines})==1,out
 assert sum(l.startswith('┌') for l in lines)==1 and sum(l.startswith('└') for l in lines)==1
 print('PASS single aligned frame with wrapped IPv6')
 # Mock external effects; only the message severity should differ.
 mocks='nft(){ cat >/dev/null; }; logger(){ :; }; systemctl(){ return 1; }; sync(){ :; }; '
 check('normal transaction info',mocks+'quarantine_locked "应用事务进行中" 1',('[INFO]','临时隔离'),('[ERR]',))
 check('real fault still error',mocks+'quarantine_locked "测试故障"',('[ERR]','请通过 VNC 恢复'))

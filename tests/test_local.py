"""Local regression tests: mocks are used for external commands, no firewall is installed."""
from pathlib import Path
import subprocess as sp,tempfile,os,json
SRC=Path(__file__).resolve().parents[1] / 'vps-fw.sh';results=[]
with tempfile.TemporaryDirectory(prefix='fw310-test-') as td:
 root=Path(td);lib=root/'lib.sh';lib.write_text(SRC.read_text().rsplit('main "$@"',1)[0])
 def test(name,body,inputs='',expected=0,inspect=None):
  d=root/str(len(results));d.mkdir()
  pre='''source "$1"
trap - EXIT
CONF_DIR="$2/conf"; DRAFT_DIR="$2/draft"; EXEC_PATH="$2/bin/fw"; BIN_LINK="$2/bin/link"; LOCK_FILE="$2/lock"
detect_wan_if(){ echo eth0; }; detect_ssh_port(){ echo 22; }; pause_prompt(){ :; }; clear_screen(){ :; }
CFG_WAN_IF=eth0
save_conf "$DRAFT_DIR" || exit 91
touch "$DRAFT_DIR/rules.db"
'''
  r=sp.run(['bash','-c',pre+body,'test',str(lib),str(d)],input=inputs,text=True,capture_output=True,timeout=15,env={**os.environ,'LC_ALL':'C'})
  good=(r.returncode==expected if expected>=0 else r.returncode!=0)
  if inspect:good=good and inspect(r,d)
  row={'test':name,'pass':good,'exit':r.returncode};results.append(row)
  print(json.dumps(row),flush=True)
  if not good:print(r.stdout[-1500:],r.stderr[-1500:])
 test('valid_default_render','render_nft_ruleset "$DRAFT_DIR" "$2/out.nft"')
 for name,config in [('wan_trust_conflict','CFG_TRUSTED_IFS=eth0'),('invalid_ssh_port','CFG_SSH_MODE=whitelist; CFG_SSH_PORT=65536; CFG_SSH_SOURCES=192.0.2.1'),('invalid_ssh_sources','CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=any'),('invalid_next_id','CFG_NEXT_ID=bad'),('invalid_outbound_policy','CFG_OUTBOUND_POLICY=wat'),('invalid_ping','CFG_PING_ALLOW=bad'),('invalid_duration','CFG_ROLLBACK_SECS=90000')]:
  test(name,config+'\nsave_conf "$DRAFT_DIR"\necho sentinel > "$2/out.nft"\nrender_nft_ruleset "$DRAFT_DIR" "$2/out.nft"',expected=-1,inspect=lambda r,d:(d/'out.nft').read_text()=='sentinel\n')
 for choice,setup,inputs in [('trust','','5\neth0\n'),('wan','CFG_TRUSTED_IFS=wg0\n','8\nwg0\n')]:
  test('menu_'+choice+'_rejects_conflict',setup+'save_conf "$DRAFT_DIR"\ncp "$DRAFT_DIR/fw.conf" "$2/before"\naction_presets_menu',inputs,expected=-1,inspect=lambda r,d:(d/'before').read_bytes()==(d/'draft/fw.conf').read_bytes())
 test('ping_toggle_keeps_saved_ssh_port','CFG_SSH_PORT=2222; CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=192.0.2.1\nsave_conf "$DRAFT_DIR"\naction_presets_menu\nload_conf "$DRAFT_DIR"\n[[ "$CFG_SSH_PORT" == 2222 ]]','4\n')
 test('ipv6_strict_valid','for v in :: ::1 2001:db8::1 2001:db8:1:2:3:4:5:6 ::/0 fe80::/10; do validate_ipv6_cidr "$v" || exit 7; done')
 test('ipv6_strict_invalid','for v in :::1 :1:: ::1: :1 1: 1::2::3 1:2:3:4:5:6:7 1:2:3:4:5:6:7:8:9 2001:zz::1 2001:db8::/129 1:2:3:4:5:6:7::8; do validate_ipv6_cidr "$v" && exit 7; done; exit 0')
 for name,rows in [('duplicate_id','1|1|accept|in|host|tcp|22|any|a\n1|1|drop|in|host|tcp|22|any|b'),('bad_action','1|1|wat|in|host|tcp|22|any|a'),('bad_cidr','1|1|accept|in|host|tcp|22|:::/999|a'),('wrong_port_proto','1|1|accept|in|host|any|22|any|a'),('missing_fields','1|1|accept')]:
  test('reject_db_'+name,"cat > \"$DRAFT_DIR/rules.db\" <<'ROWS'\n"+rows+'\nROWS\nrender_nft_ruleset "$DRAFT_DIR" "$2/out.nft"',expected=-1)
 test('failed_flock_never_runs_body','flock(){ return 1; }; body(){ touch "$2/ran"; }; with_lock body',expected=-1,inspect=lambda r,d:not (d/'ran').exists())
 test('failed_config_write_propagates','cat(){ return 1; }; save_conf "$DRAFT_DIR"',expected=-1)
 test('failed_rule_append_propagates','rm "$DRAFT_DIR/rules.db"; mkdir "$DRAFT_DIR/rules.db"; add_rule_to_dir "$DRAFT_DIR" 1 accept in host tcp 22 any test',expected=-1)
 test('failed_renderer_write_propagates','cat(){ return 1; }; render_nft_ruleset "$DRAFT_DIR" "$2/out.nft"',expected=-1,inspect=lambda r,d:not (d/'out.nft').exists())
 test('same_payload_during_pending_allowed','mkdir -p "$(dirname "$EXEC_PATH")" "$CONF_DIR"; cp "$1" "$EXEC_PATH"; chmod 755 "$EXEC_PATH"; touch "$CONF_DIR/pending.state"; install_payload "$1"')
 test('changed_payload_during_pending_rejected','mkdir -p "$(dirname "$EXEC_PATH")" "$CONF_DIR"; echo old > "$EXEC_PATH"; touch "$CONF_DIR/pending.state"; install_payload "$1"',expected=-1,inspect=lambda r,d:(d/'bin/fw').read_text()=='old\n')
 test('invalid_pending_expires','mkdir -p "$CONF_DIR"; echo nonsense > "$CONF_DIR/pending.state"; pending_expired')
 test('future_pending_expires','mkdir -p "$CONF_DIR"; printf "START_EPOCH=9999999999\\nSECS=300\\n" > "$CONF_DIR/pending.state"; pending_expired')
 test('fresh_pending_not_expired','mkdir -p "$CONF_DIR"; printf "START_EPOCH=%s\\nSECS=300\\n" "$(date +%s)" > "$CONF_DIR/pending.state"; pending_expired',expected=1)
 test('ipv4_leading_zeros_rejected','validate_ipv4_cidr 010.0.0.1',expected=-1)
 test('priority_move_works','printf "1|1|accept|in|host|tcp|22|any|a\\n2|1|drop|in|host|tcp|22|192.0.2.1|b\\n" > "$DRAFT_DIR/rules.db"; action_manage_rules','3\n2\nu\n',inspect=lambda r,d:(d/'draft/rules.db').read_text().startswith('2|'))
 test('web_preset_write_failure_propagates','add_rule_to_dir(){ return 1; }; action_presets_menu','3\n',expected=-1,inspect=lambda r,d:'已添加 80,443' not in r.stdout)
 test('preview_invalid_config_reports_error','CFG_SSH_MODE=whitelist; CFG_SSH_SOURCES=any; save_conf "$DRAFT_DIR"; action_diagnostics','1\n',expected=-1,inspect=lambda r,d:'预览失败' in r.stderr and 'table inet' not in r.stdout)
 test('docker_audit_pauses','docker(){ return 1; }; pause_prompt(){ echo PAUSED; }; action_docker_audit',expected=-1,inspect=lambda r,d:'PAUSED' in r.stdout)
 test('unknown_config_field_rejected','echo \'OUTBOUNDPOLICY="drop"\' >> "$DRAFT_DIR/fw.conf"; render_nft_ruleset "$DRAFT_DIR" "$2/out.nft"',expected=-1)
 test('missing_policy_field_rejected','sed \'/^OUTBOUND_POLICY=/d\' "$DRAFT_DIR/fw.conf" > "$2/new"; mv "$2/new" "$DRAFT_DIR/fw.conf"; render_nft_ruleset "$DRAFT_DIR" "$2/out.nft"',expected=-1)
 test('duplicate_config_field_rejected','echo \'OUTBOUND_POLICY="accept"\' >> "$DRAFT_DIR/fw.conf"; render_nft_ruleset "$DRAFT_DIR" "$2/out.nft"',expected=-1)
 test('unknown_cli_rejected','id(){ echo 0; }; main nonexistent-command',expected=-1,inspect=lambda r,d:'未知命令' in r.stderr)
 for command in ['status','docker-audit']:
  test(command+'_never_deletes_config','mkdir -p "$CONF_DIR"; echo sentinel > "$CONF_DIR/fw.conf"; render_dashboard(){ :; }; render_rules_table(){ :; }; action_docker_audit(){ :; }; id(){ echo 0; }; trap cleanup_exit EXIT; main '+command,inspect=lambda r,d:(d/'conf/fw.conf').read_text()=='sentinel\n')
Path(__file__).with_name('v3.1.0-local-results.json').write_text(json.dumps(results,indent=2))
raise SystemExit(0 if all(x['pass'] for x in results) else 1)

"""Local regression tests: mocks are used for external commands, no firewall is installed."""
from pathlib import Path
import subprocess as sp,tempfile,os,json
SRC=Path(__file__).resolve().parents[1] / 'vps-fw.sh';results=[]
with tempfile.TemporaryDirectory(prefix='vps-fw-test-') as td:
 root=Path(td);lib=root/'lib.sh';lib.write_text(SRC.read_text().rsplit('main "$@"',1)[0])
 def test(name,body,inputs='',expected=0,inspect=None):
  d=root/str(len(results));d.mkdir()
  pre='''source "$1"
trap - EXIT
CONF_DIR="$2/conf"; DRAFT_DIR="$2/draft"; EXEC_PATH="$2/bin/fw"; BIN_LINK="$2/bin/link"; LOCK_FILE="$2/lock"; GUARD_LOCK_FILE="$2/guard"; WATCH_BUSY_FILE="$2/busy"
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
 test('unterminated_drop_compiled', 'printf %s "1|1|drop|out|host|tcp|443|any|deny" > "$DRAFT_DIR/rules.db"; render_nft_ruleset "$DRAFT_DIR" "$2/out.nft"', inspect=lambda r,d:'comment "rule-1"' in (d/'out.nft').read_text())
 test('unterminated_invalid_rejected', 'printf %s "1|1|INVALID|out|host|tcp|443|any|deny" > "$DRAFT_DIR/rules.db"; validate_rule_database "$DRAFT_DIR"', expected=1)
 test('prefix_zero_rejected', 'validate_ipv6_cidr 2001:db8::/064', expected=1)
 test('ssh_shadow_warning', 'printf "%s\\n" "1|1|drop|in|host|tcp|22|any|deny" "2|1|accept|in|host|tcp|22|any|allow" > "$DRAFT_DIR/rules.db"; draft_ssh_lockout_reason', inspect=lambda r,d:'规则 #1' in r.stdout)
 test('ssh_new_port_default_no', 'action_presets_menu', '12\n2222\ny\n\n', inspect=lambda r,d:(d/'draft/rules.db').read_text()=='')
 test('ssh_new_port_explicit_source', 'action_presets_menu', '12\n2222\ny\ny\n192.0.2.9\n', inspect=lambda r,d:'|2222|192.0.2.9|' in (d/'draft/rules.db').read_text())
 test('ssh_any_needs_second_confirmation', 'action_presets_menu', '12\n2222\ny\ny\nany\n\n', inspect=lambda r,d:(d/'draft/rules.db').read_text()=='')
 test('strict_no_implicit_vpn_accept', 'CFG_TRUSTED_IFS=wg0; CFG_OUTBOUND_POLICY=drop; save_conf "$DRAFT_DIR"; render_nft_ruleset "$DRAFT_DIR" "$2/out.nft"', inspect=lambda r,d:'oifname "wg0" accept' not in (d/'out.nft').read_text())
 test('explicit_out_rule_all_interfaces', 'printf "%s\\n" "1|1|accept|out|host|tcp|443|192.0.2.9|allow" > "$DRAFT_DIR/rules.db"; render_nft_ruleset "$DRAFT_DIR" "$2/out.nft"', inspect=lambda r,d:any('comment "rule-1"' in x and 'oifname' not in x for x in (d/'out.nft').read_text().splitlines()))
 test('incompatible_upgrade_keeps_binary', 'mkdir -p "$CONF_DIR" "$2/bin"; echo old > "$EXEC_PATH"; ln -s generations/bad "$CONF_DIR/current"; valid_generation(){ return 1; }; install_payload "$1"', expected=1, inspect=lambda r,d:(d/'bin/fw').read_text()=='old\n')
 test('fault_blocks_release', 'mkdir -p "$CONF_DIR"; touch "$CONF_DIR/fault.state"; systemctl(){ echo inactive; }; nft(){ touch "$CONF_DIR/nft_called"; }; release_quarantine_locked', expected=1, inspect=lambda r,d:not (d/'conf/nft_called').exists())
 test('watch_busy_returns_75', 'flock(){ return 75; }; watch_audit', expected=75)
 test('watch_stuck_lock_fails', 'flock(){ return 75; }; echo 1 > "$WATCH_BUSY_FILE"; watch_audit', expected=1)
 test('watch_success_resets_busy', 'flock(){ return 0; }; cmd_audit(){ return 0; }; echo 1 > "$WATCH_BUSY_FILE"; watch_audit', inspect=lambda r,d:not (d/'busy').exists())
 test('append_after_unterminated_row', 'printf %s "1|1|drop|out|host|tcp|443|any|deny" > "$DRAFT_DIR/rules.db"; CFG_NEXT_ID=2; save_conf "$DRAFT_DIR"; add_rule_to_dir "$DRAFT_DIR" 1 accept in host tcp 22 any ssh >/dev/null; validate_rule_database "$DRAFT_DIR"', inspect=lambda r,d:len((d/'draft/rules.db').read_text().splitlines())==2)
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
 # Execute the library through stdin, with an actual unrelated file named main.
 # This catches Bash 5's function-level BASH_SOURCE behavior; no installation is allowed.
 pipe_dir=root/'pipe-main';pipe_dir.mkdir();(pipe_dir/'main').write_text('untrusted')
 pipe_code=lib.read_text()+"\ntrap - EXIT\nwith_lock(){ \"$@\"; }\ninstall_payload(){ touch attempted; return 1; }\nRAW_URL=invalid\nmain(){ self_install_if_needed; }\nmain\n"
 r=sp.run(['bash','-s'],input=pipe_code,text=True,capture_output=True,cwd=pipe_dir,timeout=15)
 row={'test':'piped_main_file_never_installed','pass':r.returncode!=0 and not (pipe_dir/'attempted').exists() and '固定 40 位 commit' in r.stderr,'exit':r.returncode};results.append(row);print(json.dumps(row),flush=True)
Path(__file__).with_name('v3.1.1-local-results.json').write_text(json.dumps(results,indent=2))
raise SystemExit(0 if all(x['pass'] for x in results) else 1)

"""Transaction regression in temporary directories; no real nft/systemd calls."""
from pathlib import Path
import subprocess, tempfile
src=Path(__file__).resolve().parents[1]/'vps-fw.sh'
with tempfile.TemporaryDirectory() as tmp:
 root=Path(tmp);lib=root/'lib';lib.write_text(src.read_text().rsplit('main "$@"',1)[0])
 pre='''source "$1"; trap - EXIT
CONF_DIR="$2/conf"; DRAFT_DIR="$2/draft"; DEMO_MODE=0; CFG_WAN_IF=eth0
save_conf "$DRAFT_DIR"; : > "$DRAFT_DIR/rules.db"
mkdir -p "$CONF_DIR/generations"
sync(){ :; }; systemctl(){ return 0; }; write_systemd_units(){ :; }
# macOS mv lacks -T; preserve the tested atomic rename semantics.
mv(){ if [[ "${1:-}" == -Tf ]]; then python3 -c 'import os,sys; os.replace(sys.argv[1],sys.argv[2])' "$2" "$3"; else command mv "$@"; fi; }
valid_generation(){ [[ -d "$1" && ! -f "$1/bad" ]]; }
render_nft_ruleset(){ printf 'mock nft\\n' > "$2"; }
sha256sum(){ shasum -a 256 "$@"; }
quarantine(){ echo "$1" > "$CONF_DIR/locked.state"; }
reassert_quarantine(){ return 1; }
release_quarantine(){ rm -f "$CONF_DIR/locked.state"; }
live_table_hash(){ printf hash; }
install_live_nft(){ [[ "${FAIL_INSTALL:-0}" == 0 ]] || return 1; readlink "$CONF_DIR/current" > "$CONF_DIR/loaded"; echo hash > "$(fprint_file "$CONF_DIR")"; }
expire(){ printf 'TOKEN=x\\nSTART_EPOCH=1\\nSECS=1\\n' > "$(pend_file "$CONF_DIR")"; }
apply(){ apply_draft_to_system "$1" >/dev/null || exit 90; }
'''
 def test(name,body):
  d=root/name;d.mkdir()
  r=subprocess.run(['bash','-c',pre+body,'test',str(lib),str(d)],capture_output=True,text=True,timeout=20)
  assert r.returncode==0,(name,r.stdout,r.stderr)
  print('PASS',name)
 test('first_install_has_no_baseline','apply 1; expire; cmd_audit && exit 2; test -f "$CONF_DIR/locked.state"')
 test('timeout_restores_confirmed','apply 0; old=$(readlink "$CONF_DIR/current"); apply 1; expire; cmd_audit || exit 2; test "$(readlink "$CONF_DIR/current")" = "$old" && test "$(cat "$CONF_DIR/loaded")" = "$old" && test ! -f "$(pend_file "$CONF_DIR")" && test ! -f "$CONF_DIR/locked.state"')
 test('repeated_trials_keep_baseline','apply 0; old=$(cat "$CONF_DIR/confirmed"); apply 1; apply 1; test "$(cat "$CONF_DIR/confirmed")" = "$old" || exit 2; expire; cmd_audit || exit 3; test "$(readlink "$CONF_DIR/current")" = "$old"')
 test('confirmation_advances_baseline','apply 0; apply 1; cmd_confirm || exit 2; old=$(readlink "$CONF_DIR/current"); test "$(cat "$CONF_DIR/confirmed")" = "$old" || exit 3; apply 1; expire; cmd_audit || exit 4; test "$(readlink "$CONF_DIR/current")" = "$old"')
 test('upgrade_captures_healthy_baseline','apply 0; old=$(readlink "$CONF_DIR/current"); rm "$CONF_DIR/confirmed"; apply 1; expire; cmd_audit || exit 2; test "$(readlink "$CONF_DIR/current")" = "$old"')
 test('bad_target_stays_isolated','apply 0; old=$(cat "$CONF_DIR/confirmed"); apply 1; touch "$CONF_DIR/$old/bad"; expire; cmd_audit && exit 2; test -f "$CONF_DIR/locked.state"')
 test('kernel_tampering_not_rollback','apply 0; apply 1; expire; live_table_hash(){ echo other; }; cmd_audit && exit 2; test -f "$CONF_DIR/locked.state" && test -f "$(pend_file "$CONF_DIR")"')
 test('load_failure_isolates','apply 0; apply 1; expire; FAIL_INSTALL=1; cmd_audit && exit 2; test -f "$CONF_DIR/locked.state" && test -f "$(pend_file "$CONF_DIR")"')
 test('late_confirm_restores_not_confirms_trial','apply 0; old=$(cat "$CONF_DIR/confirmed"); apply 1; expire; cmd_confirm && exit 2; test "$(readlink "$CONF_DIR/current")" = "$old" && test ! -f "$(pend_file "$CONF_DIR")"')
 test('invalid_timer_isolates','apply 0; apply 1; echo broken > "$(pend_file "$CONF_DIR")"; cmd_audit && exit 2; test -f "$CONF_DIR/locked.state"')
 test('manual_isolation_never_reopens','apply 0; apply 1; expire; quarantine manual; cmd_audit && exit 2; test "$(cat "$CONF_DIR/locked.state")" = manual')
 test('pending_reboot_stays_isolated','apply 0; apply 1; boot_restore && exit 2; test -f "$CONF_DIR/locked.state"')

 test('restores_rule_database_not_only_pointer','apply 0; printf "1|1|accept|in|host|tcp|443|any|trial\\n" > "$DRAFT_DIR/rules.db"; apply 1; test -s "$(rules_file "$CONF_DIR")" || exit 2; expire; cmd_audit || exit 3; test ! -s "$(rules_file "$CONF_DIR")"')
 test('clock_rollback_isolates','apply 0; apply 1; printf "START_EPOCH=9999999999\\nSECS=300\\n" > "$(pend_file "$CONF_DIR")"; cmd_audit && exit 2; test -f "$CONF_DIR/locked.state"')

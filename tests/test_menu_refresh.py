"""PTY checks for idle redraw; all configuration and firewall actions are mocked."""
import os, pty, select, subprocess, tempfile, time
from pathlib import Path

src = Path(__file__).resolve().parents[1] / 'vps-fw.sh'
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    lib = root / 'lib.sh'
    lib.write_text(src.read_text().rsplit('main "$@"', 1)[0])
    for pending in (True, False):
        conf = root / str(pending)
        conf.mkdir()
        (conf / 'fw.conf').touch()
        if pending:
            (conf / 'pending.state').touch()
        code = '''source "$1"; trap - EXIT
CONF_DIR="$2"; DRAFT_DIR="$2"; CHANGES_PENDING=0
init_draft_from_conf(){ :; }; clear_screen(){ :; }
render_dashboard(){ printf '\\nFRAME\\n'; }; render_rules_table(){ :; }
action_apply_confirm_menu(){ printf '\\nSELECT6\\n'; }
interactive_loop
'''
        master, slave = pty.openpty()
        proc = subprocess.Popen(['bash', '-c', code, 'test', str(lib), str(conf)], stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()
        def collect(seconds):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                ready, _, _ = select.select([master], [], [], min(.1, max(0, end-time.monotonic())))
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
        try:
            collect(.3)
            assert output.count(b'FRAME') == 1, output
            if pending:
                os.write(master, b'6')
            collect(5.6)
            assert output.count(b'FRAME') == (2 if pending else 1), output
            if pending:
                assert b'SELECT6' not in output, output
                os.write(master, b'\n')
                collect(.3)
                assert output.count(b'SELECT6') == 1, output
                # Editing remains functional; 9 is erased, then 0 exits.
                os.write(master, b'9\x7f0\n')
            else:
                os.write(master, b'0\n')
            collect(.3)
            assert proc.wait(timeout=3) == 0, output
            print('PASS', '5-second redraw preserves partial input, Enter and Backspace' if pending else 'no pending state: no automatic redraw')
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)

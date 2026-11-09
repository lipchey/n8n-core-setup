import json
import os
from pathlib import Path
import pty
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'scripts/initialize.sh').read_text()
PROMPTS = ROOT / 'scripts/lib/prompts.sh'


class Wizard(unittest.TestCase):
    def setUp(self):
        sandbox = tempfile.TemporaryDirectory(prefix='.wizard-test-', dir=ROOT)
        self.addCleanup(sandbox.cleanup)
        self.root = Path(sandbox.name)
        self.env = dict(os.environ, TMPDIR=str(self.root), LC_ALL='C', LANG='C',
                        _PV_TTY_IN='/dev/stdin', _PV_TTY_OUT='/dev/stderr')
        self.base = f'''set -eo pipefail
source "{PROMPTS}"
ENV_CONFIG="{self.root}/config"
ENV_FILE="{self.root}/secrets"
PROJECT_NAME=example
_email_re='^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{{2,}}$'
_percent_re='^([1-9][0-9]?|100)$'
_beep() {{ :; }}
'''

    def shell(self, code, input='', **env):
        return subprocess.run(['/bin/bash', '-c', self.base + code], input=input,
                              capture_output=True, text=True, cwd=self.root,
                              env=dict(self.env, **env), timeout=10)

    def successful(self, code, **kwargs):
        result = self.shell(code, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_database_defaults_and_rerun_without_questions(self):
        start = SOURCE.index('upsert_env "N8N_LOCAL_API_URL"')
        end = SOURCE.index('# Never regenerate — changing BACKUP_PASSWORD', start)
        block = SOURCE[start:end]
        code = '''N8N_LOCAL_API_URL=http://localhost:5678/api/v1
prompt_value() { echo 'Unexpected database question' >&2; return 99; }
'''
        self.successful(code + block)
        first = (self.root / 'secrets').read_text()
        self.assertIn('DB_USER=n8n_db_user\n', first)
        self.assertIn('DB_NAME=n8n_database\n', first)
        password = re.search(r'^DB_PASSWORD=(.+)$', first, re.M)[1]
        self.assertGreaterEqual(len(password), 32)
        self.successful(code + 'source "$ENV_FILE"\n' + block)
        self.assertEqual((self.root / 'secrets').read_text(), first)
        self.successful(code + 'DB_USER=saved_user; DB_NAME=saved_db; DB_PASSWORD=saved_password\n' + block)
        saved = (self.root / 'secrets').read_text()
        for value in ('DB_USER=saved_user', 'DB_NAME=saved_db', 'DB_PASSWORD=saved_password'):
            self.assertIn(value, saved)

    def test_bucket_name_without_questions_and_saved_name(self):
        block = re.search(r'^if \[ "\$_want_backblaze" = "y" \]; then\n.*?^fi', SOURCE, re.M | re.S)[0]
        code = '''_want_backblaze=y; _b2_preconfigured=y
prompt_value() { echo 'Unexpected bucket question' >&2; return 99; }
'''
        result = self.successful(code + block + '\nprintf "FINAL=%s" "$BACKBLAZE_BUCKET"')
        self.assertIn('FINAL=example-backups', result.stdout)
        self.assertFalse((self.root / 'config').exists())
        (self.root / 'config').write_text('BACKBLAZE_BUCKET=saved-bucket\n')
        self.successful(code + 'source "$ENV_CONFIG"\n' + block)
        self.assertEqual((self.root / 'config').read_text(), 'BACKBLAZE_BUCKET=saved-bucket\n')
        result = self.successful('_want_backblaze=n; BACKBLAZE_BUCKET=saved-bucket\n' + block
                                 + '\nprintf "FINAL=%s\\n" "$BACKBLAZE_BUCKET"')
        self.assertIn('FINAL=saved-bucket', result.stdout)

    def alerts(self, setup='', input='\n\n'):
        start = SOURCE.index('if [ "$_want_disk_alerts" = "y" ]; then')
        end = SOURCE.index('section_header "Workflow health ping (optional)"', start)
        return self.successful('''_want_disk_alerts=y
RESEND_API_KEY=re_fixture
DEVELOPER_EMAIL=developer@example.com
''' + setup + '\n' + SOURCE[start:end], input=input)

    def test_threshold_defaults_and_saved_values(self):
        self.alerts('N8N_COMMON_DOMAIN=example.com')
        config = (self.root / 'config').read_text()
        self.assertIn('ALERT_DISK_THRESHOLD_MEDIUM=85\n', config)
        self.assertIn('ALERT_DISK_THRESHOLD_HIGH=95\n', config)
        self.alerts('''_is_rerun=true
ALERT_DISK_THRESHOLD_MEDIUM=80; ALERT_DISK_THRESHOLD_HIGH=90
RESEND_FROM_EMAIL=saved@example.com
upsert_env RESEND_FROM_EMAIL "$RESEND_FROM_EMAIL"
env_keys_snapshot "$ENV_FILE"''', input='')
        config = (self.root / 'config').read_text()
        self.assertIn('ALERT_DISK_THRESHOLD_MEDIUM=80\n', config)
        self.assertIn('ALERT_DISK_THRESHOLD_HIGH=90\n', config)

    def test_sender_defaults_both_modes_and_saved_value(self):
        for setup, expected in (
            ('N8N_COMMON_DOMAIN=agency.example', 'alerts@agency.example'),
            ('N8N_PROJECTS_DOMAIN=n8n.example.com', 'alerts@example.com'),
            ('N8N_PROJECTS_DOMAIN=example.com', 'alerts@example.com'),
            ('N8N_PROJECTS_DOMAIN=ops.customer.example', 'alerts@customer.example'),
            ('N8N_PROJECTS_DOMAIN=ops.eu.customer.example', 'alerts@eu.customer.example'),
            ('N8N_COMMON_DOMAIN=agency.example; RESEND_FROM_EMAIL=saved@example.com', 'saved@example.com'),
        ):
            with self.subTest(setup=setup):
                self.alerts(setup)
                self.assertIn(f'RESEND_FROM_EMAIL={expected}\n', (self.root / 'secrets').read_text())
        result = self.alerts('', input='\n\ninvalid\nvalid@example.com\n')
        self.assertIn('Required', result.stderr)
        self.assertIn('Invalid format', result.stderr)
        self.assertIn('RESEND_FROM_EMAIL=valid@example.com\n', (self.root / 'secrets').read_text())

    def health_ping(self, responses, input='', setup=''):
        executable = self.root / 'curl'
        executable.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TMPDIR'])
args = sys.argv[1:]
config = sys.stdin.read() if '-K' in args else ''
with (root / 'health-calls').open('a') as log:
    key = config.split('X-Api-Key: ', 1)[1].split('"', 1)[0] if config else args[args.index('-H') + 1].removeprefix('X-Api-Key: ')
    log.write(json.dumps({'args': args, 'config': config, 'exported_key': key in os.environ.values()}) + '\\n')
counter = root / 'health-counter'
index = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(index + 1))
status, body, rc = json.loads(os.environ['HEALTH_RESPONSES'])[index]
print(json.dumps(body) if isinstance(body, dict) else body)
if '-w' in args:
    print(status, end='')
sys.exit(rc)
""")
        executable.chmod(0o700)
        start = SOURCE.index('section_header "Workflow health ping (optional)"')
        end = SOURCE.index('upsert_env "HEALTH_PING_URL"', start)
        end = SOURCE.index('\n', end)
        result = self.shell(setup + '\n' + SOURCE[start:end], input=input,
                            PATH=f'{self.root}:{os.environ["PATH"]}',
                            HEALTH_RESPONSES=json.dumps(responses))
        calls = self.root / 'health-calls'
        return result, [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    def assert_health_key_private(self, result, calls, *keys):
        for key in keys:
            self.assertNotIn(key, result.stdout + result.stderr)
            for call in calls:
                self.assertFalse(call['exported_key'])
                self.assertNotIn(key, ' '.join(call['args']))
            for path in self.root.iterdir():
                if path.is_file() and path.name not in ('health-calls', 'curl'):
                    self.assertNotIn(key, path.read_text())

    def test_health_api_key_creates_check_without_persisting_or_exporting_key(self):
        key = 'health_fixture_secret'
        url = 'https://hc-ping.com/fixture'
        result, calls = self.health_ping([['201', {'ping_url': url}, 0]], input=key + '\n',
                                         setup='export _hc_api_key=preexisting_export')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn('X-Api-Key: ' + key, calls[0]['config'])
        self.assertEqual(calls[0]['args'][-1], 'https://healthchecks.io/api/v3/checks/')
        payload = json.loads(calls[0]['args'][calls[0]['args'].index('-d') + 1])
        self.assertEqual(payload, dict(name='example', timeout=600, grace=1800, channels='*', unique=['name']))
        self.assertEqual((self.root / 'secrets').read_text(), f'HEALTH_PING_URL={url}\n')
        self.assertIn('API key', result.stderr)
        self.assertNotIn('Ping URL (leave blank', result.stderr)
        self.assert_health_key_private(result, calls, key)

    def test_health_api_error_shows_status_and_reason_then_retries(self):
        bad, good = 'invalid_health_secret', 'valid_health_secret'
        result, calls = self.health_ping([
            ['401', {'error': 'Invalid key ' + bad}, 0],
            ['200', {'ping_url': 'https://hc-ping.com/retried'}, 0],
        ], input=bad + '\n' + good + '\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn('401', result.stdout + result.stderr)
        self.assertIn('Invalid key', result.stdout + result.stderr)
        self.assert_health_key_private(result, calls, bad, good)

    def test_health_blank_skips_without_api_call(self):
        result, calls = self.health_ping([], input='\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual((self.root / 'secrets').read_text(), 'HEALTH_PING_URL=\n')
        self.assertIn('API key', result.stderr)

    def test_health_saved_url_and_developer_key_skip_question(self):
        result, calls = self.health_ping([], setup='HEALTH_PING_URL=https://hc-ping.com/saved')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, [])
        result, calls = self.health_ping([['201', {'ping_url': 'https://hc-ping.com/developer'}, 0]],
                                         setup='HEALTHCHECKS_API_KEY=developer_fixture_key')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn('X-Api-Key: developer_fixture_key', calls[0]['config'])
        self.assertNotIn('API key:', result.stderr)
        self.assertNotIn('developer_fixture_key', (self.root / 'secrets').read_text())

    def test_health_transport_and_malformed_success_can_be_skipped(self):
        for response in (['000', '', 28], ['200', 'not json', 0],
                         ['403', {'ping_url': 'https://hc-ping.com/rejected', 'error': 'Denied'}, 0]):
            with self.subTest(response=response):
                result, calls = self.health_ping([response], input='health_secret\n\n')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls), 1)
                self.assertIn(response[0], result.stdout + result.stderr)
                self.assertEqual((self.root / 'secrets').read_text(), 'HEALTH_PING_URL=\n')
                self.assert_health_key_private(result, calls, 'health_secret')
                (self.root / 'health-calls').unlink()
                (self.root / 'health-counter').unlink()

    def host_keys(self):
        self.host_home = self.root / 'home'
        self.host_home.mkdir()
        self.scan = self.root / 'scan'
        for name in ('host', 'stale'):
            result = subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.root / name)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.scan.write_text('192.0.2.1 ' + (self.root / 'host.pub').read_text())
        self.fingerprint = subprocess.check_output(['ssh-keygen', '-lf', str(self.root / 'host.pub')], text=True).split()[1]
        self.stale_fingerprint = subprocess.check_output(['ssh-keygen', '-lf', str(self.root / 'stale.pub')], text=True).split()[1]
        return self.host_home / '.ssh/known_hosts'

    def trust_host(self, pinned='', retries=0):
        match = re.search(r'^trust_vps_host_key\(\) \{\n.*?^\}', SOURCE, re.M | re.S)
        function = match[0] if match else 'trust_vps_host_key() { echo "host trust helper missing" >&2; return 127; }'
        code = function + f'''
N8N_VPS_IP=192.0.2.1
N8N_VPS_HOST_FINGERPRINT="{pinned}"
N8N_SSH_OPTS=(-o ConnectTimeout=10)
ssh-keyscan() {{
    printf '%s\\n' "$*" >> "{self.root}/scans"
    local count=0
    [ ! -f "{self.root}/scan-count" ] || count=$(cat "{self.root}/scan-count")
    printf '%s' "$((count + 1))" > "{self.root}/scan-count"
    [ "$count" -ge {retries} ] || return 1
    cat "{self.scan}"
}}
sleep() {{ :; }}
ssh() {{ touch "{self.root}/connected"; }}
trust_vps_host_key || exit $?
printf 'OPTIONS=%s\\n' "${{N8N_SSH_OPTS[*]}}"
ssh
'''
        return self.shell(code, HOME=str(self.host_home))

    def test_host_trust_matches_pin_and_is_idempotent(self):
        known = self.host_keys()
        for _ in range(2):
            result = self.trust_host(self.fingerprint)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(known.read_text(), self.scan.read_text())
            self.assertEqual(known.stat().st_mode & 0o777, 0o600)
            self.assertEqual(known.parent.stat().st_mode & 0o777, 0o700)
            self.assertIn('StrictHostKeyChecking=yes', result.stdout)
        self.assertTrue(all('-t ed25519' in line for line in (self.root / 'scans').read_text().splitlines()))

    def test_host_trust_replaces_stale_ip_and_preserves_other_hosts(self):
        known = self.host_keys()
        known.parent.mkdir()
        other = '192.0.2.2 ' + (self.root / 'stale.pub').read_text()
        known.write_text('192.0.2.1 ' + (self.root / 'stale.pub').read_text() + other)
        result = self.trust_host(self.fingerprint)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(known.read_text(), other + self.scan.read_text())

    def test_host_mismatch_stops_without_touching_known_hosts_or_connecting(self):
        known = self.host_keys()
        known.parent.mkdir(mode=0o755)
        known.write_text(self.scan.read_text())
        before = known.read_bytes()
        result = self.trust_host(self.stale_fingerprint)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(known.read_bytes(), before)
        self.assertEqual(known.parent.stat().st_mode & 0o777, 0o755)
        self.assertFalse((self.root / 'connected').exists())
        for fingerprint in (self.fingerprint, self.stale_fingerprint):
            self.assertIn(fingerprint, result.stdout + result.stderr)

    def test_host_without_pin_trusts_the_scanned_key_and_enforces_it(self):
        known = self.host_keys()
        known.parent.mkdir()
        known.write_text('192.0.2.1 ' + (self.root / 'stale.pub').read_text())
        for pinned in ('', 'SHA256:paste_fingerprint_here'):
            result = self.trust_host(pinned)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('StrictHostKeyChecking=yes', result.stdout)
            self.assertIn(self.fingerprint, result.stdout + result.stderr)
            self.assertEqual(known.read_text(), self.scan.read_text())

    def test_host_scan_retries_then_stops_when_unavailable(self):
        known = self.host_keys()
        result = self.trust_host(self.fingerprint, retries=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'scan-count').read_text(), '3')
        (self.root / 'scan-count').unlink()
        before = known.read_bytes()
        result = self.trust_host(self.fingerprint, retries=100)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(known.read_bytes(), before)
        self.assertLessEqual(int((self.root / 'scan-count').read_text()), 5)

    def test_host_trust_precedes_first_wizard_connection_and_key_types_match(self):
        self.assertIn('\ntrust_vps_host_key || exit 1', SOURCE)
        self.assertLess(SOURCE.index('\ntrust_vps_host_key || exit 1'), SOURCE.index('\nssh_n8n_stdin bash <<'))
        self.assertNotIn('ssh-keyscan -t ecdsa', SOURCE)
        self.assertNotIn('ssh-keyscan -t ecdsa', (ROOT / 'scripts/test-environment.sh').read_text())

    def test_environment_verifies_ed25519_when_server_also_offers_ecdsa(self):
        self.host_keys()
        key = self.root / 'ecdsa'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ecdsa', '-N', '', '-f', str(key)], check=True,
                       capture_output=True, timeout=10)
        env_file = self.root / '.env'
        saved = f'N8N_VPS_HOST_FINGERPRINT={self.fingerprint}\nCUSTOM_OPTION=saved\n'
        env_file.write_text(saved)
        source = (ROOT / 'scripts/test-environment.sh').read_text()
        function = re.search(r'^test_env_fingerprint\(\) \{\n.*?^\}', source, re.M | re.S)[0]
        result = self.shell(function + f'''
SCRIPT_DIR="{self.root}/scripts"
N8N_VPS_IP=192.0.2.1
info() {{ :; }}
warn() {{ :; }}
err() {{ :; }}
prompt_dev() {{ return 1; }}
ssh-keyscan() {{
    case "$*" in
        *ecdsa*) printf '192.0.2.1 '; cat "{key}.pub" ;;
        *) cat "{self.scan}" ;;
    esac
}}
test_env_fingerprint
''', HOME=str(self.host_home))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(env_file.read_text(), saved)

    def live_function(self, name):
        source = (ROOT / 'scripts/test-environment.sh').read_text()
        return re.search(r'^' + name + r'\(\) \{\n.*?^\}\n(?=\n)', source, re.M | re.S)[0]

    def test_environment_fingerprint_mismatch_never_rewrites_secrets(self):
        self.host_keys()
        saved = f'N8N_VPS_HOST_FINGERPRINT={self.stale_fingerprint}\nCUSTOM_OPTION=saved\n'
        for encrypted in (False, True):
            with self.subTest(encrypted=encrypted):
                (self.root / '.env').unlink(missing_ok=True)
                env_file = self.root / ('.env.sops.yaml' if encrypted else '.env')
                env_file.write_text(saved)
                env_file.chmod(0o600)
                result = self.shell(self.live_function('test_env_fingerprint') + f'''
SCRIPT_DIR="{self.root}/scripts"
N8N_VPS_IP=192.0.2.1
info() {{ printf '%s\\n' "$*"; }}
warn() {{ info "$@"; }}
err() {{ info "$@"; }}
prompt_dev() {{ echo UNEXPECTED_PERMISSION; }}
ssh-keyscan() {{ cat "{self.scan}"; }}
bash() {{ cat "{env_file}"; }}
test_env_fingerprint
''', HOME=str(self.host_home))
                self.assertEqual(env_file.read_text(), saved)
                self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)
                self.assertNotEqual(result.returncode, 0)
                for text in (self.fingerprint, self.stale_fingerprint, 'provider console',
                             'npm run encrypt-env'):
                    self.assertIn(text, result.stdout + result.stderr)
                self.assertNotIn('UNEXPECTED_PERMISSION', result.stdout)
                env_file.unlink()

    def disk_email(self, log='MEDIUM alert email sent to developer@example.com.', trigger_rc=0, prompt_rc=99):
        return self.shell(self.live_function('test_disk_check_email') + r'''
set +e
C_BOLD=; C_RESET=
info() { printf '%s\n' "$*"; }
warn() { info "$@"; }
err() { info "$@"; }
prompt_dev() { echo UNEXPECTED_PERMISSION; return "$PROMPT_RC"; }
confirm_dev() { printf 'CONFIRM:%s\n' "$*"; }
ssh_n8n() {
    case "$*" in
        *"grep -c"*) echo 1 ;;
        *DEVELOPER_EMAIL*) echo developer@example.com ;;
        *ALERT_DISK_THRESHOLD*) echo 85 ;;
        *"wc -l"*) echo 0 ;;
        "bash -s") cat >/dev/null; echo SEND; return "$TRIGGER_RC" ;;
        *"tail -n"*) printf '%s\n' "$SEND_LOG" ;;
        *) echo 'Unexpected SSH call' >&2; return 99 ;;
    esac
}
test_disk_check_email
''', SEND_LOG=log, TRIGGER_RC=str(trigger_rc), PROMPT_RC=str(prompt_rc))

    def test_disk_email_sends_before_delivery_confirmation_without_permission(self):
        result = self.disk_email()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('UNEXPECTED_PERMISSION', result.stdout)
        self.assertLess(result.stdout.index('SEND'), result.stdout.index('CONFIRM:'))
        self.assertIn('Spam', result.stdout)
        self.assertIn('developer@example.com', result.stdout)

    def test_disk_email_send_failures_stop_before_confirmation(self):
        for log, trigger_rc, reason in (
            ('send_email: Resend returned HTTP 422: invalid sender\nFAILED to send email via Resend', 0, 'HTTP 422'),
            ('Email not configured — no email sent.', 0, 'no email sent'),
            ('', 0, 'delivery'),
            ('', 23, '23'),
        ):
            with self.subTest(log=log, trigger_rc=trigger_rc):
                result = self.disk_email(log, trigger_rc, prompt_rc=0)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('CONFIRM:', result.stdout)
                self.assertIn(reason, result.stdout + result.stderr)

    def error_email(self, status='200', curl_rc=0, prompt_rc=99, delivery=True):
        (self.root / 'triggered').unlink(missing_ok=True)
        return self.shell(self.live_function('test_error_handler_email') + r'''
set +e
C_BOLD=; C_RESET=; C_YELLOW=
info() { printf '%s\n' "$*"; }
warn() { info "$@"; }
err() { info "$@"; }
prompt_dev() { echo UNEXPECTED_PERMISSION; return "$PROMPT_RC"; }
confirm_dev() { printf 'CONFIRM:%s\n' "$*"; }
sleep() { :; }
ssh_n8n() {
    if [ "$*" = 'bash -s' ]; then
        local remote
        remote=$(cat)
        case "$remote" in
            *'SELECT COUNT(*)'*) echo 1 ;;
            *lastErrorEmailSent*)
                if [ -f triggered ] && [ "$DELIVERY_RECORDED" = true ]; then echo 2000000; else echo 0; fi ;;
            *'Global Error Handler'*) echo true ;;
            *'Fail on Purpose'*) echo 'fixture|true' ;;
            *) echo 'Unexpected remote script' >&2; return 99 ;;
        esac
    else
        case "$*" in
            *"grep -c"*) echo 1 ;;
            *WEBHOOK_URL*) echo https://example.invalid ;;
            *DEVELOPER_EMAIL*) echo developer@example.com ;;
            *PROJECT_NAME*) echo example ;;
            *'date +%s'*) echo 2000 ;;
            *) echo 'Unexpected SSH call' >&2; return 99 ;;
        esac
    fi
}
curl() {
    touch triggered
    printf '%s' "$WEBHOOK_HTTP"
    return "$CURL_RC"
}
test_error_handler_email
''', WEBHOOK_HTTP=status, CURL_RC=str(curl_rc), PROMPT_RC=str(prompt_rc),
            DELIVERY_RECORDED=str(delivery).lower())

    def test_error_email_triggers_before_delivery_confirmation_without_permission(self):
        result = self.error_email()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / 'triggered').exists())
        self.assertNotIn('UNEXPECTED_PERMISSION', result.stdout)
        self.assertIn('CONFIRM:', result.stdout)
        self.assertIn('Spam', result.stdout)

    def test_error_email_rejected_or_unreachable_webhook_stops_before_confirmation(self):
        for status, curl_rc in (('401', 0), ('403', 0), ('404', 0), ('500', 0), ('000', 7), ('200', 7)):
            with self.subTest(status=status, curl_rc=curl_rc):
                result = self.error_email(status, curl_rc, prompt_rc=0)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.root / 'triggered').exists())
                self.assertNotIn('CONFIRM:', result.stdout)
                self.assertIn('HTTP ' + status, result.stdout)
                self.assertIn('curl exit ' + str(curl_rc), result.stdout)

    def test_error_email_without_successful_send_stops_before_confirmation(self):
        result = self.error_email(prompt_rc=0, delivery=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'triggered').exists())
        self.assertNotIn('CONFIRM:', result.stdout)
        self.assertIn('successful email delivery', result.stdout)
        self.assertIn('Send Error Email', result.stdout)

    def github_token_check(self, endpoint='repo', status='200', curl_rc=0):
        creds = self.root / 'backup-creds'
        creds.write_text('GITHUB_PERSONAL_ACCESS_TOKEN=secret_fixture_never_print\nGITHUB_REPO=owner/repo\n')
        function = self.live_function('test_github_commit_prereqs').replace('/root/n8n/.backup_creds', str(creds))
        result = self.shell(function + r'''
set +e
GITHUB_REPO=owner/repo
info() { printf '%s\n' "$*"; }
err() { info "$@"; }
ssh_n8n() {
    printf '%s\n' "$*" >> transport-args
    [ "$1" = bash ] || return 0
    local remote
    remote=$(cat)
    /bin/bash -c "$remote"
}
curl() {
    local url status=200 rc=0
    for url; do :; done
    if [[ "$url" == *"/$FAIL_ENDPOINT"* ]]; then status=$TOKEN_HTTP; rc=$CURL_RC; fi
    if [ "$rc" -ne 0 ]; then printf '000'; return "$rc"; fi
    if [ "$status" -ge 400 ] && [[ "$*" == *' -sf '* || "$1" == -sf ]]; then return 22; fi
    if [[ "$url" == */user ]]; then printf '{"login":"fixture"}'; else printf '{"full_name":"owner/repo"}'; fi
    [[ "$*" != *'%{http_code}'* ]] || printf '\n%s' "$status"
    return 0
}
export -f curl
test_github_commit_prereqs
''', FAIL_ENDPOINT='user' if endpoint == 'user' else 'repos', TOKEN_HTTP=status, CURL_RC=str(curl_rc))
        self.assertNotIn('secret_fixture_never_print', result.stdout + result.stderr)
        self.assertTrue((self.root / 'transport-args').exists(), result.stdout + result.stderr)
        self.assertNotIn('secret_fixture_never_print', (self.root / 'transport-args').read_text())
        return result

    def test_github_token_failures_show_status_repo_and_reason_without_token(self):
        for endpoint in ('user', 'repo'):
            for status, reason in (('401', 'invalid or expired'), ('403', 'permission'),
                                   ('404', 'no access'), ('503', 'curl exit 0')):
                with self.subTest(endpoint=endpoint, status=status):
                    result = self.github_token_check(endpoint, status)
                    self.assertNotEqual(result.returncode, 0)
                    for text in ('HTTP ' + status, 'GITHUB_REPO=owner/repo', reason):
                        self.assertIn(text, result.stdout + result.stderr)

    def test_github_token_transport_failure_shows_status_and_curl_exit(self):
        result = self.github_token_check(curl_rc=7)
        self.assertNotEqual(result.returncode, 0)
        for text in ('HTTP 000', 'curl exit 7', 'GITHUB_REPO=owner/repo'):
            self.assertIn(text, result.stdout + result.stderr)

    def test_github_token_success_checks_login_and_repo(self):
        result = self.github_token_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('fixture', result.stdout)
        self.assertIn('owner/repo', result.stdout)

    def test_env_rewrites_drop_retired_alert_keys_and_preserve_custom_keys(self):
        keys = ('ALERTS_TELEGRAM_BOT_TOKEN', 'ALERTS_TELEGRAM_CHAT_ID',
                'N8N_LOGIN_EMAIL', 'N8N_LOGIN_PASSWORD')
        functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE, re.M | re.S)[0]
                              for name in ('write_env_config', 'write_env_file'))
        for name in ('config', 'secrets'):
            (self.root / name).write_text(''.join(f'{key}=retired_fixture\n' for key in keys)
                                          + 'CUSTOM_OPTION=preserved\n')
        self.successful(functions + '\nwrite_env_config\nwrite_env_file')
        for name in ('config', 'secrets'):
            contents = (self.root / name).read_text()
            self.assertIn('CUSTOM_OPTION=preserved\n', contents)
            for key in keys:
                self.assertNotIn(key, contents)

    def deploy(self, responses):
        binary = self.root / 'bin'
        binary.mkdir(exist_ok=True)
        curl = binary / 'curl'
        curl.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TMPDIR'])
calls = root / 'curl-calls'
index = len(calls.read_text().splitlines()) if calls.exists() else 0
with calls.open('a') as log:
    log.write(sys.argv[-1] + '\\n')
responses = json.loads(os.environ['DEPLOY_RESPONSES'])
status, body = responses[min(index, len(responses) - 1)]
if status == '000':
    sys.exit(7)
if int(status) >= 400 and '-sf' in sys.argv:
    sys.exit(22)
sys.stdout.write(json.dumps(body))
if '-w' in sys.argv:
    sys.stdout.write('\\n' + status)
''')
        curl.chmod(0o700)
        start = SOURCE.index('# Wait for GitHub Actions deploy to succeed')
        end = SOURCE.index('# Normalize workflow JSON', start)
        block = SOURCE[start:end].replace('>/dev/tty', '>"$_PV_TTY_OUT"').replace('</dev/tty', '<"$_PV_TTY_IN"')
        for name in ('curl-calls', 'gh-calls'):
            (self.root / name).unlink(missing_ok=True)
        result = self.shell('''ROOT_DIR="$TMPDIR"; GITHUB_REPO=acme/project; GITHUB_BRANCH=main
GITHUB_PERSONAL_ACCESS_TOKEN=never-print-this-token; _failures=()
git() { printf 'fixture-sha'; }
sleep() { :; }
_check_gh_state() { printf ready; }
gh() { printf '%s\\n' "$*" >> "$TMPDIR/gh-calls"; }
ask_yn() { echo UNEXPECTED_QUESTION; return 1; }
''' + block + '\nprintf "RESULT=%s\\n" "$_run_ok"',
                            PATH=f'{binary}:{os.environ["PATH"]}', DEPLOY_RESPONSES=json.dumps(responses))
        output = result.stdout + result.stderr
        self.assertNotIn('never-print-this-token', output)
        return result, output, (self.root / 'gh-calls').read_text() if (self.root / 'gh-calls').exists() else ''

    def test_deploy_reports_http_errors_without_dispatch(self):
        for status in ('401', '403', '404', '500', '000'):
            with self.subTest(status=status):
                result, output, calls = self.deploy([(status, {'message': 'failure'})])
                self.assertEqual(result.returncode, 0, output)
                self.assertIn('HTTP ' + status, output)
                self.assertNotIn('No new deploy run', output)
                self.assertEqual(calls, '')
                self.assertEqual(len((self.root / 'curl-calls').read_text().splitlines()), 1)
                if status in ('401', '403', '404'):
                    self.assertIn('token', output.lower())
                    self.assertIn('permission', output.lower())

    def test_deploy_dispatches_automatically_and_follows_the_run(self):
        responses = [('200', {'workflow_runs': []})] * 8 + [
            ('200', {'workflow_runs': [{'id': 42}]}),
            ('200', {'status': 'completed', 'conclusion': 'success'})]
        result, output, calls = self.deploy(responses)
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('RESULT=true', output)
        self.assertEqual(calls.splitlines(), ['workflow run deploy.yml --repo acme/project --ref main'])
        self.assertNotIn('UNEXPECTED_QUESTION', output)

    def test_deploy_dispatches_at_most_once_when_no_run_appears(self):
        result, output, calls = self.deploy([('200', {'workflow_runs': []})])
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(calls.count('workflow run'), 1)
        self.assertNotIn('UNEXPECTED_QUESTION', output)

    def test_deploy_existing_run_needs_no_dispatch(self):
        result, output, calls = self.deploy([('200', {'workflow_runs': [{'id': 42}]}),
                                            ('200', {'status': 'completed', 'conclusion': 'success'})])
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('RESULT=true', output)
        self.assertEqual(calls, '')

    def test_deploy_completion_poll_reports_permission_error(self):
        result, output, calls = self.deploy([('200', {'workflow_runs': [{'id': 42}]}),
                                            ('403', {'message': 'forbidden'})])
        self.assertEqual(result.returncode, 0, output)
        self.assertIn('HTTP 403', output)
        self.assertNotIn('Timeout', output)
        self.assertEqual(calls, '')

    def owner_setup(self, input='', key='', status='200'):
        start = SOURCE.index('_api_valid=false')
        end = SOURCE.index('# n8n MCP setup moved below', start)
        block = SOURCE[start:end].replace('>/dev/tty', '>"$_PV_TTY_OUT"').replace('</dev/tty', '<"$_PV_TTY_IN"')
        (self.root / 'api-count').unlink(missing_ok=True)
        return self.shell('''WEBHOOK_URL=https://fixture.example.invalid
_n8n_local_url=http://localhost:5678/api/v1; HARD_RESET=false; _failures=()
N8N_LOGIN_EMAIL=legacy@example.invalid; N8N_LOGIN_PASSWORD=legacy-secret
_clipboard_copy() { cat >/dev/null; echo none; }
ssh_n8n_stdin() {
  cat > "$TMPDIR/ssh-input"
  case "$*" in *curl*)
    cat "$TMPDIR/ssh-input" >> "$TMPDIR/api-probes"
    local count=0 statuses
    [ ! -f "$TMPDIR/api-count" ] || count=$(cat "$TMPDIR/api-count")
    IFS=, read -r -a statuses <<< "$API_STATUS"
    echo "${statuses[$count]:-${statuses[${#statuses[@]}-1]}}"
    echo "$((count + 1))" > "$TMPDIR/api-count"
    ;;
  esac
}
''' + f'N8N_API_KEY="{key}"\n' + block, input=input, API_STATUS=status)

    def test_owner_setup_uses_manual_credentials_and_shared_links(self):
        result = self.owner_setup(input='\nfixture-key\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('use your own email and a strong password, and save them in your password manager', result.stdout)
        self.assertIn('https://fixture.example.invalid/settings/api', result.stdout)
        self.assertNotIn('legacy-secret', result.stdout + result.stderr)
        self.assertNotIn('legacy@example.invalid', result.stdout + result.stderr)
        self.assertNotIn('retry', result.stdout + result.stderr)
        block = SOURCE[SOURCE.index('if [ "$_api_valid" = "false" ]; then'):SOURCE.index('# n8n MCP setup moved below')]
        self.assertIn('section_header ', block)
        self.assertIn('print_link "$WEBHOOK_URL"', block)
        self.assertIn('print_link "${WEBHOOK_URL}/settings/api"', block)

    def test_api_key_empty_retries_and_secret_is_saved(self):
        result = self.owner_setup(input='\n\nfixture-key\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / 'secrets').is_file(), 'Required key was skipped')
        self.assertIn('N8N_API_KEY=fixture-key\n', (self.root / 'secrets').read_text())
        self.assertEqual(result.stderr.count('Paste N8N_API_KEY:'), 2)
        self.assertNotIn('fixture-key', result.stdout + result.stderr)
        self.assertEqual((self.root / 'ssh-input').read_text(), 'fixture-key\n')

    def test_api_key_eof_stops_and_valid_saved_key_skips_questions(self):
        result = self.owner_setup(input='\n\n')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        result = self.owner_setup(key='saved-key', status='200')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('ACTION REQUIRED', result.stdout)
        self.assertNotIn('Paste N8N_API_KEY', result.stderr)

    def test_pasted_api_key_retries_http_failures_before_saving(self):
        result = self.owner_setup(input='\ninvalid-key\nforbidden-key\noffline-key\nvalid-key\n',
                                  status='401,403,000,200')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for status in ('401', '403', '000'):
            self.assertIn('HTTP ' + status, result.stdout + result.stderr)
        self.assertEqual(result.stderr.count('Paste N8N_API_KEY:'), 4)
        self.assertEqual((self.root / 'secrets').read_text(), 'N8N_API_KEY=valid-key\n')
        self.assertEqual((self.root / 'api-count').read_text(), '4\n')

    def test_pasted_api_key_rejection_then_eof_stops_without_saving(self):
        result = self.owner_setup(input='\ninvalid-key\n', status='401')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('HTTP 401', result.stdout + result.stderr)
        self.assertFalse((self.root / 'secrets').exists())

    def github_access(self, repo):
        function = re.search(r'^_validate_github_token\(\) \{\n.*?^\}', SOURCE, re.M | re.S)[0]
        result = self.shell(r'''
GITHUB_REPO=owner/repo
curl() {
  printf '%s\n' "$@" >> "$TMPDIR/token-args"
  if [[ " $* " == *' -K - '* ]]; then cat >> "$TMPDIR/token-config"; fi
  case "${!#}" in
    */user) printf '{"login":"fixture"}' ;;
    */actions/*) printf '{"workflow_runs":[]}' ;;
    *) printf '%s' "$REPO_RESPONSE" ;;
  esac
}
''' + function + '\n_validate_github_token pat_fixture_secret', REPO_RESPONSE=json.dumps(repo))
        return result

    def test_pat_check_only_claims_repository_access(self):
        for repo in ({'full_name': 'owner/repo'}, {'full_name': 'owner/repo', 'permissions': {'push': False}}):
            with self.subTest(repo=repo):
                result = self.github_access(repo)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Contents write is confirmed by the first workflow publish from the VPS', SOURCE)

    def test_local_curl_keeps_pat_health_and_b2_secrets_out_of_arguments(self):
        with self.subTest(service='PAT'):
            result = self.github_access({'full_name': 'owner/repo'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('pat_fixture_secret', (self.root / 'token-args').read_text())
            self.assertIn('pat_fixture_secret', (self.root / 'token-config').read_text())
        with self.subTest(service='healthchecks'):
            result, calls = self.health_ping([['201', {'ping_url': 'https://hc-ping.com/fixture'}, 0]],
                                            input='health_fixture_secret\n')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assert_health_key_private(result, calls, 'health_fixture_secret')
        with self.subTest(service='B2'):
            function = re.search(r'^  _b2_authorize\(\) \{\n.*?^  \}', SOURCE, re.M | re.S)[0]
            result = self.shell(r'''
    BACKBLAZE_KEY_ID=b2_fixture_id; BACKBLAZE_APPLICATION_KEY=b2_fixture_secret
    curl() {
      printf '%s\n' "$@" > "$TMPDIR/b2-args"
      if [[ " $* " == *' -K - '* ]]; then cat > "$TMPDIR/b2-config"; fi
      printf '{"authorizationToken":"fixture"}'
    }
    ''' + function + '\n_b2_authorize')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('b2_fixture_secret', (self.root / 'b2-args').read_text())
            self.assertIn('b2_fixture_id:b2_fixture_secret', (self.root / 'b2-config').read_text())

    def test_push_does_not_mutate_repository_settings(self):
        block = SOURCE[SOURCE.index('_git_push() '):SOURCE.index('# Wait for GitHub Actions deploy')]
        result = self.successful('''ROOT_DIR="$TMPDIR"; GITHUB_PUSH_REMOTE=origin; GITHUB_BRANCH=main; GITHUB_REPO=acme/project
git() { :; }
retry_or_skip() { shift; "$@"; }
gh() { echo "$*" >> "$TMPDIR/settings-calls"; }
''' + block)
        self.assertFalse((self.root / 'settings-calls').exists(), result.stdout)

    def test_example_values_are_consistent_and_placeholders_load_as_empty(self):
        example = ROOT / '.env.example'
        fixed = {'N8N_LOCAL_API_URL': 'http://localhost:5678/api/v1', 'N8N_LOG_LEVEL': 'info',
                 'DB_USER': 'n8n_db_user', 'DB_NAME': 'n8n_database', 'N8N_VPS_USER': 'root'}
        generated = {'N8N_ENCRYPTION_KEY', 'DB_PASSWORD', 'BACKUP_PASSWORD', 'HEALTH_PING_URL',
                     'N8N_VPS_IP', 'N8N_VPS_HOST_FINGERPRINT', 'CF_ACCESS_CLIENT_ID', 'CF_ACCESS_CLIENT_SECRET'}
        for line in example.read_text().splitlines():
            if not line or line.startswith('#'):
                continue
            key, value = line.split('=', 1)
            with self.subTest(key=key):
                if key in fixed:
                    self.assertEqual(value, fixed[key])
                elif key in generated:
                    self.assertEqual(value, 'auto_generated')
                else:
                    self.assertRegex(value, r'^paste_.+_here$')
        fixture = self.root / 'example'
        fixture.write_text(example.read_text() + '\nCUSTOM_TOKEN=paste_custom_token_here\nCUSTOM_GENERATED=auto_generated\nCUSTOM_REAL=real-value\n')
        result = self.successful(f'''load_env_file "{fixture}"
for key in N8N_ENCRYPTION_KEY DIGITAL_OCEAN_API_TOKEN HETZNER_API_TOKEN CF_ACCESS_CLIENT_SECRET CUSTOM_TOKEN CUSTOM_GENERATED; do
  [ -z "${{!key:-}}" ] || exit 88
  [ -z "$(file_var "{fixture}" "$key")" ] || exit 89
done
[ "$CUSTOM_REAL" = real-value ]
[ "$DB_USER" = n8n_db_user ]
''')
        self.assertEqual(result.returncode, 0)

    def test_provider_env_reads_clear_placeholders_before_token_validation(self):
        for provider, key in (('digitalocean', 'DIGITAL_OCEAN_API_TOKEN'), ('hetzner', 'HETZNER_API_TOKEN')):
            with self.subTest(provider=provider):
                source = (ROOT / f'scripts/init-{provider}.sh').read_text()
                start = source.index('ENV_CONFIG=')
                end = source.index('PV_LABEL=')
                block = source[start:end].replace('source "$SCRIPT_DIR/lib/prompts.sh"', ':').replace('source "$SCRIPT_DIR/lib/provision-vps.sh"', ':')
                (self.root / '.env').write_text(f'{key}=paste_provider_token_here\n')
                self.successful(f'ROOT_DIR="{self.root}"\n' + block + f'\n[ -z "${{{key}:-}}" ]')

    def test_backblaze_prune_discards_placeholder_credentials(self):
        source = (ROOT / 'scripts/prune-backblaze.sh').read_text()
        block = source[source.index('if [ ! -f "$ENV_CONFIG" ]; then'):source.index('\n: "${BACKBLAZE_KEY_ID:')]
        (self.root / 'config').write_text('PROJECT_NAME=example\n')
        (self.root / 'secrets').write_text('BACKBLAZE_KEY_ID=paste_keyID_here\nBACKBLAZE_APPLICATION_KEY=paste_applicationKey_here\n')
        self.successful(block + '\n[ -z "${BACKBLAZE_KEY_ID:-}" ] && [ -z "${BACKBLAZE_APPLICATION_KEY:-}" ]')

    def test_github_setup_has_no_obsolete_prerequisite_fallbacks(self):
        self.assertFalse('gh CLI not available' in SOURCE)
        start = SOURCE.index('section_header "GitHub Push Protection"')
        block = SOURCE[start:SOURCE.index('echo "▶  Step 4/4:', start)]
        for obsolete in ('not_installed)', 'unauthenticated)', 'brew install gh', 'gh auth login'):
            self.assertFalse(obsolete in block, obsolete)
        result = self.successful('''GITHUB_REPO=owner/repo
_enable_github_push_protection() { echo 'fixture API failure' >&2; return 1; }
''' + block)
        self.assertIn('fixture API failure', result.stderr)
        self.assertIn('Enable manually', result.stdout)
        self.assertIn('Push Protection NOT enabled', result.stdout)

    def b2(self, responses, buckets=(), saved=False, lock='n'):
        executable = self.root / 'curl'
        executable.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TMPDIR'])
args = sys.argv[1:]
payload = json.loads(args[args.index('-d') + 1])
with (root / 'calls').open('a') as log:
    log.write(json.dumps([args[-1], payload]) + '\\n')
if args[-1].endswith('/b2_list_buckets'):
    print(os.environ['B2_LIST'])
else:
    counter = root / 'counter'
    index = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(index + 1))
    response = json.loads(os.environ['B2_RESPONSES'])[index]
    if response == 'transport': sys.exit(28)
    if response == 'success': response = dict(bucketId='fixture-id', bucketName=payload['bucketName'])
    if response == 'malformed': print('not json')
    else: print(json.dumps(response))
''')
        executable.chmod(0o700)
        match = re.search(r'^_b2_create_bucket\(\) \{\n.*?^\}', SOURCE, re.M | re.S)
        function = match[0] if match else '_b2_create_bucket() { return 127; }'
        code = function + f'''
BACKBLAZE_BUCKET=example-backups
_b2_api_url=http://stub.invalid
_b2_auth_token=fixture-token
_b2_real_account_id=fixture-account
_b2_use_lock={lock}
'''
        if saved:
            code += 'upsert_env_config BACKBLAZE_BUCKET "$BACKBLAZE_BUCKET"\nenv_keys_snapshot "$ENV_CONFIG"\n'
        code += '''_b2_create_bucket
printf 'FINAL=%s ID=%s\\n' "$BACKBLAZE_BUCKET" "$_b2_bucket_id"
'''
        result = self.shell(code, PATH=f'{self.root}:{os.environ["PATH"]}',
                            B2_RESPONSES=json.dumps(responses), B2_LIST=json.dumps({'buckets': list(buckets)}))
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()] if (self.root / 'calls').exists() else []
        return result, calls

    def test_b2_collision_retries_and_persists_final_name(self):
        result, calls = self.b2([{'code': 'duplicate_bucket_name'}, 'success'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        creates = [payload for url, payload in calls if url.endswith('/b2_create_bucket')]
        self.assertEqual(len(creates), 2)
        final = creates[-1]['bucketName']
        self.assertRegex(final, r'^example-backups-[a-z0-9]{6}$')
        self.assertIn(f'FINAL={final} ID=fixture-id', result.stdout)
        self.assertIn(f'BACKBLAZE_BUCKET={final}\n', (self.root / 'config').read_text())

    def test_b2_default_remains_retryable_after_an_interrupted_run(self):
        block = re.search(r'^if \[ "\$_want_backblaze" = "y" \]; then\n.*?^fi', SOURCE, re.M | re.S)[0]
        self.successful('_want_backblaze=y; _b2_preconfigured=y\n' + block)
        self.successful('load_env_file "$ENV_CONFIG"\nenv_keys_snapshot "$ENV_CONFIG"\n'
                        + 'if _pv_key_saved BACKBLAZE_BUCKET; then exit 91; fi')
        result, calls = self.b2([{'code': 'duplicate_bucket_name'}, 'success'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sum(url.endswith('/b2_create_bucket') for url, _ in calls), 2)

    def test_b2_saved_bucket_reused_without_renaming(self):
        bucket = dict(bucketId='existing-id', bucketName='example-backups',
                      fileLockConfiguration={'value': {'isFileLockEnabled': True}})
        result, calls = self.b2([{'code': 'duplicate_bucket_name'}], [bucket], saved=True, lock='y')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('FINAL=example-backups ID=existing-id', result.stdout)
        self.assertEqual(len(calls), 2)
        self.assertEqual((self.root / 'config').read_text(), 'BACKBLAZE_BUCKET=example-backups\n')

    def test_b2_other_errors_do_not_retry(self):
        for response in ({'code': 'unauthorized'}, {'code': 'bad_request'}, 'transport', 'malformed'):
            with self.subTest(response=response):
                result, calls = self.b2([response])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)
                (self.root / 'calls').unlink()
                (self.root / 'counter').unlink()

    def test_b2_collisions_are_bounded_and_saved_names_stay(self):
        duplicate = {'code': 'duplicate_bucket_name'}
        result, calls = self.b2([duplicate] * 4)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum(url.endswith('/b2_create_bucket') for url, _ in calls), 4)
        (self.root / 'calls').unlink()
        (self.root / 'counter').unlink()
        result, calls = self.b2([duplicate], saved=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2)
        self.assertEqual((self.root / 'config').read_text(), 'BACKBLAZE_BUCKET=example-backups\n')

    def test_headers_have_fixed_character_width_and_balanced_dashes(self):
        titles = re.findall(r'^\s*section_header "(.+)"$', SOURCE, re.M)
        self.assertGreater(len(titles), 15)
        for title in titles + ['VPS creation', 'Resend — email']:
            with self.subTest(title=title):
                result = self.successful(f'section_header "{title}"')
                line = result.stdout.rstrip('\n')
                self.assertEqual(len(line), 72)
                match = re.fullmatch(r'  (─+) (.+?) (─+)', line)
                self.assertIsNotNone(match, line)
                self.assertEqual(match[2], title.upper())
                self.assertIn(len(match[3]) - len(match[1]), (0, 1))

    def test_link_output_terminal_and_pipe(self):
        url = 'https://example.invalid/setup'
        result = self.successful(f'print_link "{url}"')
        self.assertEqual(result.stdout, url + '\n')
        master, slave = pty.openpty()
        try:
            result = subprocess.run(['/bin/bash', '-c', self.base + f'print_link "{url}"'],
                                    stdout=slave, stderr=subprocess.PIPE, env=self.env, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = os.read(master, 4096)
            self.assertEqual(output, f'\x1b]8;;{url}\x1b\\{url}\x1b]8;;\x1b\\\r\n'.encode())
        finally:
            os.close(master)
            os.close(slave)

    def test_link_can_append_action_text_outside_the_hyperlink(self):
        result = self.successful('print_link "https://example.invalid/api" " → click Create API key"')
        self.assertEqual(result.stdout, 'https://example.invalid/api → click Create API key\n')

    def test_user_links_use_the_shared_helper(self):
        leftovers = []
        for path in (ROOT / 'scripts').rglob('*.sh'):
            if path.name.startswith('test-') and path.name != 'test-environment.sh':
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if re.match(r'\s*(echo|printf|info|warn|err)\s.*https?://', line):
                    if 'echo "deb [arch=' not in line:
                        leftovers.append(f'{path.name}:{number}')
                if r'\033]8;;' in line and path != PROMPTS:
                    leftovers.append(f'{path.name}:{number}: duplicate OSC 8')
        self.assertEqual(leftovers, [])


if __name__ == '__main__':
    unittest.main()

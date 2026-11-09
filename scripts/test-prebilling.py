import fcntl
import json
import pty
import select
import termios
import time
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROMPTS = ROOT / 'scripts/lib/prompts.sh'
PROVISION = ROOT / 'scripts/lib/provision-vps.sh'
INITIALIZE = ROOT / 'scripts/initialize.sh'


def function(path, name):
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}', path.read_text(), re.M | re.S)
    return match[0] if match else f'{name}() {{ return 127; }}'


class Prebilling(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix='.prebilling-test-', dir=ROOT)
        self.addCleanup(self.sandbox.cleanup)
        self.root = Path(self.sandbox.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for tool in ('curl', 'gh', 'ssh', 'scp'):
            self.stub(tool, 'exit 99')
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.root),
                        SSH_PRIVATE_KEY='', ENV_LOCAL=str(self.root / '.env.local'),
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                        GIT_ALLOW_PROTOCOL='file', GIT_CEILING_DIRECTORIES=str(self.root), PATH=f'{self.bin}:{os.environ["PATH"]}',
                        _PV_TTY_IN='/dev/stdin', _PV_TTY_OUT='/dev/stderr')
        self.base = f'source "{PROMPTS}"; source "{PROVISION}"; '

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o700)

    def shell(self, code, input='', **env):
        return subprocess.run(['/bin/bash', '-c', self.base + code], input=input,
                              capture_output=True, text=True, cwd=self.root,
                              env=dict(self.env, **env), timeout=15)

    def git(self, *args, cwd=None):
        return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', *args],
                              cwd=cwd or self.root, env=self.env,
                              capture_output=True, text=True, check=True)

    def prerequisite(self):
        scripts = self.root / 'scripts'
        scripts.mkdir(exist_ok=True)
        shutil.copyfile(ROOT / 'scripts/check-prerequisites.sh', scripts / 'check-prerequisites.sh')
        (scripts / 'lib').mkdir(exist_ok=True)
        shutil.copyfile(PROMPTS, scripts / 'lib/prompts.sh')
        for tool in ('git', 'curl', 'node', 'npm'):
            real = shutil.which(tool)
            version = {'git': 'git version 2.40.0', 'curl': 'curl 8.0.0',
                       'node': 'v20.0.0', 'npm': '10.0.0'}[tool]
            other = f'exec "{real}" "$@"' if tool == 'git' else 'exit 99'
            self.stub(tool, f'if [ "$1" = --version ]; then echo "{version}"; else {other}; fi')
        for tool in ('jq', 'openssl', 'rsync', 'sops', 'ssh', 'scp', 'ssh-keygen',
                     'ssh-keyscan', 'age-keygen', 'pbcopy', 'afplay', 'open', 'brew'):
            self.stub(tool, 'exit 99')
        self.stub('gh', 'if [ "$1" = --version ]; then echo "gh version 2.40.0"; else [ "$*" = "auth status --active" ] || exit 99; fi')
        self.stub('uname', 'echo Darwin')
        return subprocess.run(['/bin/bash', str(scripts / 'check-prerequisites.sh')],
                              cwd=self.root, env=dict(self.env, PREREQUISITES_TTY=self.env.get('PREREQUISITES_TTY', '/dev/null')),
                              capture_output=True, text=True, timeout=15)

    def test_01_unfinished_git(self):
        self.git('init', '-q', '-b', 'main')
        for state in ('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge',
                      'rebase-apply', 'sequencer', 'index.lock'):
            with self.subTest(state=state):
                path = self.root / self.git('rev-parse', '--git-path', state).stdout.strip()
                if state in ('rebase-merge', 'rebase-apply', 'sequencer'):
                    path.mkdir()
                else:
                    path.touch()
                result = self.prerequisite()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('git status', result.stderr)
                self.assertIn(state, result.stderr)
                self.assertTrue(path.exists())
                if path.is_dir():
                    path.rmdir()
                else:
                    path.unlink()
        self.assertEqual(self.prerequisite().returncode, 0)

    def test_01_unmerged_paths_and_linked_worktree(self):
        self.git('init', '-q', '-b', 'main')
        (self.root / 'file').write_text('base')
        self.git('add', 'file')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=f@invalid', 'commit', '-qm', 'base')
        blob = self.git('hash-object', 'file').stdout.strip()
        subprocess.run(['git', 'update-index', '--index-info'], cwd=self.root, env=self.env,
                       input=f'100644 {blob} 1\tfile\n100644 {blob} 2\tfile\n100644 {blob} 3\tfile\n',
                       text=True, check=True, capture_output=True)
        result = self.prerequisite()
        self.assertEqual(result.returncode, 1)
        self.assertIn('unmerged', result.stderr.lower())
        self.git('reset', '--hard', '-q', 'HEAD')
        linked = self.root / 'linked'
        self.git('worktree', 'add', '-q', '-b', 'linked', str(linked))
        target = Path(self.git('rev-parse', '--git-path', 'index.lock', cwd=linked).stdout.strip())
        target.touch()
        self.root = linked
        result = self.prerequisite()
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(target), result.stderr)

    def test_02_access_and_03_terminal_aggregate(self):
        for name in ('.env', '.env.config', '.env.local', '.sops.yaml', '.env.sops.yaml'):
            (self.root / name).mkdir()
        (self.home / '.config').write_text('not a directory')
        self.env['TMPDIR'] = str(self.root / 'absent-tmp')
        self.env['PREREQUISITES_TTY'] = str(self.root / 'missing-tty')
        result = self.prerequisite()
        self.assertEqual(result.returncode, 1)
        for name in ('.env', '.env.config', '.env.local', '.sops.yaml', '.env.sops.yaml',
                     'absent-tmp', '.config', 'interactive terminal'):
            self.assertIn(name, result.stderr)
        self.assertFalse((self.root / 'missing-tty').exists())
        self.assertNotIn('chmod -R', result.stderr)

    @unittest.skipIf(os.geteuid() == 0, 'root bypasses filesystem mode bits')
    def test_02_probes_removed_and_existing_age_readonly(self):
        age = self.home / '.config/sops/age'
        age.mkdir(parents=True)
        age.chmod(0o500)
        try:
            result = self.prerequisite()
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(str(age), result.stderr)
            self.assertEqual(list(self.root.glob('.prerequisite*')), [])
        finally:
            age.chmod(0o700)

    @unittest.skipIf(os.geteuid() == 0, 'root bypasses filesystem mode bits')
    def test_02_age_existing_project_key_and_default_keystore_access(self):
        age = self.home / '.config/sops/age'
        age.mkdir(parents=True)
        (self.root / '.env.config').write_text('PROJECT_NAME=fixture\n')
        (age / 'fixture.txt').write_text('fixture-key\n')
        default = age / 'keys.txt'
        default.write_text('fixture-key\n')
        default.chmod(0o400)
        result = self.prerequisite()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(str(default), result.stderr)
        default.chmod(0o600)
        age.chmod(0o500)
        try:
            result = self.prerequisite()
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            age.chmod(0o700)

    @unittest.skipIf(os.geteuid() == 0, 'root bypasses filesystem mode bits')
    def test_02_permission_failures(self):
        temporary = self.root / 'temporary'
        temporary.mkdir()
        self.env['TMPDIR'] = str(temporary)
        config = self.root / '.sops.yaml'
        config.touch()
        envfile = self.root / '.env'
        envfile.touch()
        self.prerequisite()
        for path, mode in ((temporary, 0o500), (config, 0o400), (envfile, 0o000), (self.home, 0o500)):
            path.chmod(mode)
        self.root.chmod(0o500)
        try:
            result = self.prerequisite()
            self.assertEqual(result.returncode, 1)
            for path in (temporary, config, envfile, self.home, self.root):
                self.assertIn(str(path), result.stderr)
        finally:
            self.root.chmod(0o700)
            for path in (temporary, config, envfile, self.home):
                path.chmod(0o700 if path.is_dir() else 0o600)

    def test_04_real_keys_and_missing_private(self):
        sshdir = self.home / '.ssh'
        sshdir.mkdir()
        for name, password in (('plain', ''), ('locked', 'secret-passphrase')):
            key = sshdir / name
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', password, '-f', str(key)],
                           check=True, capture_output=True)
            result = self.shell(f'PROJECT_NAME=example; validate_ssh_private_key "{key}"')
            self.assertEqual(result.returncode, 0 if not password else 1, result.stdout + result.stderr)
            if password:
                self.assertIn('ssh-keygen -t ed25519 -f ~/.ssh/example_deploy -N ""', result.stderr)
                self.assertNotIn('PRIVATE KEY', result.stdout + result.stderr)
        plain = sshdir / 'plain'
        fp = subprocess.run(['ssh-keygen', '-E', 'md5', '-lf', str(plain) + '.pub'],
                            check=True, capture_output=True, text=True).stdout.split()[1].removeprefix('MD5:')
        plain.unlink()
        result = self.shell(f'pv_match_local_privkey "{fp}"; printf "MATCH=%s" "$_matched_privkey"')
        self.assertNotIn('✅ Private key found', result.stdout)
        self.assertTrue(result.stdout.endswith('MATCH='), result.stdout)

    def test_selected_key_outside_ssh_is_matched_without_public_sidecar(self):
        key = self.root / 'selected'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)],
                       check=True, capture_output=True)
        fp = subprocess.check_output(['ssh-keygen', '-E', 'md5', '-lf', str(key) + '.pub'],
                                     text=True).split()[1].removeprefix('MD5:')
        key.with_suffix('.pub').unlink()
        (self.root / '.env.local').write_text(f'SSH_PRIVATE_KEY={key}\n')
        for setup in ('', f'SSH_PRIVATE_KEY="{key}"; '):
            with self.subTest(setup=setup):
                result = self.shell('ENV_LOCAL="$TMPDIR/.env.local"; ' + setup
                                    + f'pv_match_local_privkey "{fp}"; printf "MATCH=%s" "$_matched_privkey"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.endswith(f'MATCH={key}'), result.stdout)

    def test_provider_key_mismatch_reselects_without_replacing_selected_key(self):
        sshdir = self.home / '.ssh'
        sshdir.mkdir()
        keys = [self.root / 'selected', sshdir / 'other']
        fingerprints = []
        for key in keys:
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)],
                           check=True, capture_output=True)
            fingerprints.append(subprocess.check_output(['ssh-keygen', '-E', 'md5', '-lf', str(key) + '.pub'],
                                                        text=True).split()[1].removeprefix('MD5:'))
        local = self.root / '.env.local'
        local.write_text(f'SSH_PRIVATE_KEY={keys[0]}\n')
        result = self.shell(f'''ENV_LOCAL="{local}"
pv_match_local_privkey "{fingerprints[1]}"
rc=$?
[ -z "$_matched_privkey" ] || exit 91
exit "$rc"
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('does not match', result.stdout + result.stderr)
        for provider in ('hetzner', 'digitalocean'):
            source = (ROOT / f'scripts/init-{provider}.sh').read_text()
            block = source.split('# ─── 5. SSH key', 1)[1].split('\n', 1)[1].split('# ─── 5b.', 1)[0]
            result = self.shell(f'''set -e
ENV_LOCAL="{local}"; selections=0
pv_select_ssh_key() {{
  selections=$((selections + 1))
  if [ "$selections" -eq 1 ]; then PV_KEY_FP="{fingerprints[1]}"; else PV_KEY_FP="{fingerprints[0]}"; fi
}}
''' + block + '\nprintf "SELECTIONS=%s MATCH=%s" "$selections" "$_matched_privkey"')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f'SELECTIONS=2 MATCH={keys[0]}', result.stdout)
        self.assertEqual(local.read_text(), f'SSH_PRIVATE_KEY={keys[0]}\n')

    def test_provider_failures_before_create_are_aborted(self):
        for provider in ('hetzner', 'digitalocean'):
            source = (ROOT / f'scripts/init-{provider}.sh').read_text()
            start = source.index('\n', source.index('pv_resume_saved_server')) + 1
            end = source.index('SERVER_ID="$PV_SERVER_ID"' if provider == 'hetzner' else 'DROPLET_ID="$PV_SERVER_ID"', start)
            block = source[start:end]
            result = self.shell('''set -euo pipefail
pv_api_get() { printf '{"server_types":[],"sizes":[]}'; }
''' + block)
            self.assertEqual(result.returncode, 10, result.stdout + result.stderr)
            preamble = source[start:source.index('while true; do', start)]
            no_images = re.search(r'^if \[ "\$_images_count" -eq 0 \]; then\n.*?^fi', source, re.M | re.S)[0]
            result = self.shell('set -euo pipefail\n_images_count=0; _type_arch=x86; REGION=fra1\n'
                                + preamble + no_images)
            self.assertEqual(result.returncode, 10, result.stdout + result.stderr)
            keys = source.split('# ─── 5. SSH key', 1)[1].split('\n', 1)[1].split('# ─── 5b.', 1)[0]
            result = self.shell('''set -euo pipefail
pv_select_ssh_key() { PV_KEY_FP=missing; }
''' + preamble + keys)
            self.assertEqual(result.returncode, 10, result.stdout + result.stderr)

    def test_05_and_07_preprovider_order(self):
        source = '\n'.join(line for line in INITIALIZE.read_text().splitlines()
                           if not line.lstrip().startswith('#'))
        dispatch = source.index('1) _run_provider ')
        for marker in ('validate_ssh_private_key "$SSH_PRIVATE_KEY"',
                       'npm ci --no-audit --no-fund --ignore-scripts',
                       'push --dry-run --no-verify -- "$GITHUB_PUSH_REMOTE" HEAD:refs/heads/main',
                       'upsert_env "GITHUB_PERSONAL_ACCESS_TOKEN"'):
            with self.subTest(marker=marker):
                self.assertLess(source.index(marker), dispatch)
        self.assertEqual(source.count('custom-nodes build failed — aborting'), 1)
        upload = source.index('scp_n8n -r "$ROOT_DIR/n8n"')
        between = source[source.index('custom-nodes built.'):upload]
        self.assertNotRegex(between, r'rm .*custom-nodes|npm (ci|install|prune)|git (clean|reset)')
        self.assertGreater(source.index('chmod -R a+rX /root/n8n/custom-nodes'), upload)

    def test_05_build_output_reaches_upload(self):
        nodes = self.root / 'n8n/custom-nodes'
        nodes.mkdir(parents=True)
        (nodes / 'package.json').write_text('{}')
        (nodes / 'package-lock.json').write_text('{}')
        self.stub('npm', '''printf '%s\\n' "$*" >> "$TMPDIR/npm-calls"
case "$*" in
  'ci --no-audit --no-fund --ignore-scripts') mkdir -p node_modules;;
  'run build') mkdir -p dist; printf compiled > dist/fixture;;
  'prune --omit=dev') [ -f dist/fixture ] || exit 1;;
  *) exit 99;;
esac''')
        source = INITIALIZE.read_text()
        start = source.index('if [ -f "$ROOT_DIR/n8n/custom-nodes/package.json" ]; then')
        end = source.index('\nfi', start) + 3
        upload = next(line for line in source.splitlines() if line.startswith('scp_n8n -r'))
        code = f'ROOT_DIR="{self.root}"; N8N_VPS_USER=root; N8N_VPS_IP=fixture; ' + source[start:end] + '''
scp_n8n() { [ "$1" = -r ] && [ "$(cat "$2/custom-nodes/dist/fixture")" = compiled ]; }
''' + upload
        result = self.shell(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'npm-calls').read_text().splitlines(),
                         ['ci --no-audit --no-fund --ignore-scripts', 'run build', 'prune --omit=dev'])

    def test_06_push_to_empty_then_diverged_repo(self):
        local = self.root / 'local'
        local.mkdir()
        self.git('init', '-q', '-b', 'main', str(local))
        (local / 'file').write_text('one')
        self.git('add', 'file', cwd=local)
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=f@invalid', 'commit', '-qm', 'one', cwd=local)
        remote = self.root / 'bare'
        self.git('init', '--bare', '-q', str(remote))
        source = INITIALIZE.read_text()
        block = source[source.index('if ! git -C "$ROOT_DIR"'):source.index('upsert_env_config "GITHUB_REPO"')]
        prefix = f'ROOT_DIR="{local}"; GITHUB_PUSH_REMOTE="file://{remote}"; '
        result = self.shell(prefix + block)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('--git-dir=' + str(remote), 'for-each-ref').stdout, '')
        self.assertIn('push --dry-run --no-verify', block)
        self.git('push', 'file://' + str(remote), 'HEAD:refs/heads/main', cwd=local)
        other = self.root / 'other'
        self.git('clone', '-q', '-b', 'main', 'file://' + str(remote), str(other))
        (other / 'other').write_text('two')
        self.git('add', 'other', cwd=other)
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=f@invalid', 'commit', '-qm', 'two', cwd=other)
        self.git('push', 'file://' + str(remote), 'HEAD:refs/heads/main', cwd=other)
        result = self.shell(prefix + block)
        self.assertEqual(result.returncode, 1)
        self.assertIn('diverged', result.stderr)

    def test_07_repo_pat_permissions(self):
        body = function(INITIALIZE, '_validate_github_token')
        self.stub('curl', '''printf '%s\\n' "${@: -1}" >> "$TMPDIR/calls"
case "${@: -1}" in
  */user) echo '{"login":"fixture"}' ;;
  */repos/acme/project) printf '%s' "$REPO_JSON" ;;
  */actions/runs?per_page=1) [ "$ACTIONS_STATUS" = 0 ] || exit 22; echo '{"workflow_runs":[]}' ;;
  *) exit 99 ;;
esac''')
        for repo, actions, expected, message in (
                ('{"permissions":{"push":true}}', '0', 0, ''),
                ('{"permissions":{}}', '0', 0, ''),
                ('{}', '0', 0, ''),
                ('{"permissions":{"push":false}}', '0', 0, ''),
                ('[]', '0', 1, 'access'),
                ('{"permissions":{"push":true}}', '22', 1, 'Actions')):
            with self.subTest(repo=repo, actions=actions):
                result = self.shell(body + '; GITHUB_REPO=acme/project; _validate_github_token "hidden-token"',
                                    REPO_JSON=repo, ACTIONS_STATUS=actions)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNotIn('hidden-token', result.stdout + result.stderr)
        calls = (self.root / 'calls').read_text()
        self.assertIn('/repos/acme/project\n', calls)
        self.assertIn('/actions/runs?per_page=1', calls)

    def test_07_pat_loop_rerun_and_env_rewrite(self):
        source = INITIALIZE.read_text()
        start = source.index('section_header "GitHub Personal Access Token"')
        end = source.index('\n', source.index('upsert_env "GITHUB_PERSONAL_ACCESS_TOKEN"', start))
        block = source[start:end].replace('>/dev/tty', '>"$_PV_TTY_OUT"')
        self.stub('curl', '''config=$(cat)
case "${@: -1}" in
  */user) echo '{"login":"fixture"}';;
  */repos/acme/project) case "$config" in *invalid*) exit 22;; *) echo '{"full_name":"acme/project"}';; esac;;
  */actions/runs?per_page=1) echo '{"workflow_runs":[]}';;
  *) exit 99;;
esac''')
        for saved, answers in (('', 'invalid\nvalid\n'), ('valid', '\n')):
            with self.subTest(saved=saved):
                envfile = self.root / '.env'
                envfile.write_text('EXTRA_SECRET=retained\n')
                envfile.chmod(0o600)
                code = f'ENV_FILE="{envfile}"; ENV_CONFIG="$TMPDIR/.env.config"; GITHUB_REPO=acme/project; ' + \
                    f'GITHUB_PERSONAL_ACCESS_TOKEN="{saved}"; ' + block + '\n' + \
                    function(INITIALIZE, 'write_env_file') + '\nwrite_env_file'
                result = self.shell(code, input=answers)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('GITHUB_PERSONAL_ACCESS_TOKEN=valid\n', envfile.read_text())
                self.assertIn('EXTRA_SECRET=retained\n', envfile.read_text())
                self.assertEqual(envfile.stat().st_mode & 0o777, 0o600)
                self.assertNotIn('invalid', result.stdout + result.stderr)
                if not saved:
                    self.assertIn('access to', result.stderr)

    def test_09_age_recipient_derived_and_failure(self):
        keydir = self.home / '.config/sops/age'
        keydir.mkdir(parents=True)
        (keydir / 'project.txt').write_text('fixture without public comment')
        code = function(INITIALIZE, '_ensure_age_key') + f'; ROOT_DIR="{self.root}"; PROJECT_NAME=project; _ensure_age_key'
        self.stub('age-keygen', '[ "$1" = -y ] || exit 99; echo age1derived')
        result = self.shell(code)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('age: age1derived', (self.root / '.sops.yaml').read_text())
        for stub in ('exit 1', 'exit 0'):
            self.stub('age-keygen', stub)
            result = self.shell(code)
            self.assertEqual(result.returncode, 1)
            self.assertIn('recipient', result.stderr)

    def test_10_repo_creation_without_confirmation(self):
        code = '''initialize_repo_guard() { GITHUB_PUSH_REMOTE=""; }
_check_github_repo_config() { :; }
require_private_github_repo() { :; }
gh() { case "$*" in 'api -i user') :;; 'repo create acme/project --private --source='*) echo CREATED;; *) return 99;; esac; }
prompt_value() { printf acme/project; }
ask_yn() { echo UNEXPECTED_CONFIRM >&2; return 1; }
ROOT_DIR="$TMPDIR"; PROJECT_NAME=project; GITHUB_REPO=acme/project; GITHUB_PUSH_REMOTE=""
create_private_github_repo'''
        result = self.shell(code)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CREATED', result.stdout)
        self.assertIn('private', result.stdout)
        self.assertNotIn('UNEXPECTED_CONFIRM', result.stderr)

    def test_11_timezone_fixtures(self):
        zones = self.root / 'zones'
        for zone in ('Europe/Berlin', 'America/New_York', 'UTC', 'Europe/Shared',
                     'America/Shared', 'posix/Berlin', 'right/Berlin'):
            path = zones / zone
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        (zones / 'Directory').mkdir()
        link = self.root / 'zone-link'
        link.symlink_to(zones, target_is_directory=True)
        for answer, expected in (('Berlin', 'Europe/Berlin'), ('new york', 'America/New_York'),
                                 ('Europe/Berlin', 'Europe/Berlin'), ('UTC', 'UTC')):
            with self.subTest(answer=answer):
                result = self.shell(f'resolve_timezone "{answer}"', ZONEINFO_DIR=str(link))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
        for answer in ('Shared', 'Missing', '../x', '*', 'Directory', 'posix/Berlin'):
            with self.subTest(invalid=answer):
                result = self.shell('resolve_timezone "$ANSWER"', ANSWER=answer, ZONEINFO_DIR=str(link))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
        result = self.shell('resolve_timezone Shared', ZONEINFO_DIR=str(link))
        self.assertIn('Europe/Shared', result.stderr)
        self.assertIn('America/Shared', result.stderr)

    def test_11_timezone_prompt_default_rerun_and_retry(self):
        zones = self.root / 'zones'
        for name in ('Europe/Berlin', 'America/New_York', 'Europe/Shared', 'America/Shared', 'UTC'):
            path = zones / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        pattern = re.search(r"^_tz_re='([^']+)'", INITIALIZE.read_text(), re.M)[1]
        code = f"prompt_timezone '{pattern}'"
        self.stub('readlink', 'echo /var/db/timezone/zoneinfo/Europe/Berlin')
        result = self.shell(code, input='\n', ZONEINFO_DIR=str(zones))
        self.assertEqual(result.stdout, 'Europe/Berlin')
        self.assertIn('[Europe/Berlin]', result.stderr)
        self.assertIn('Your timezone sets when scheduled workflows and server jobs run.', result.stderr)
        self.stub('readlink', 'exit 1')
        result = self.shell(code, input='\n', ZONEINFO_DIR=str(zones))
        self.assertEqual(result.stdout, 'UTC')
        result = self.shell(code, input='Shared\nMissing\nBerlin\n', ZONEINFO_DIR=str(zones))
        self.assertEqual(result.stdout, 'Europe/Berlin')
        self.assertIn('Several timezones', result.stderr)
        self.assertIn('nearest large city', result.stderr)
        result = self.shell('_is_rerun=true; _PV_SAVED_KEYS=" DISPLAY_TZ "; DISPLAY_TZ=America/New_York; ' + code,
                            ZONEINFO_DIR=str(zones))
        self.assertEqual(result.stdout, 'America/New_York')
        self.assertIn('[existing]', result.stderr)

    def test_08_hetzner_capacity_rows(self):
        def server(name, arch, locations, prices):
            return dict(name=name, architecture=arch, memory=2, cores=2, disk=40,
                        cpu_type='shared', locations=locations, prices=[
                            dict(location=loc, price_monthly=dict(gross=str(price)))
                            for loc, price in prices])
        def location(name, available=True, deprecation=None):
            return dict(id=1, name=name, available=available,
                        recommended=False, deprecation=deprecation)
        fixtures = dict(server_types=[
            server('cpx11', 'x86', [location('fsn1', False)], [('fsn1', 3)]),
            server('cax11', 'arm', [location('fsn1')], [('fsn1', 2)]),
            server('old', 'x86', [location('fsn1', deprecation={'announced': 'soon'})], [('fsn1', 1)]),
            server('cx23', 'x86', [location('fsn1', False), location('nbg1', False), location('hel1', False)], [('fsn1', 3)]),
            server('usable', 'x86', [location('fsn1'), location('hel1')], [('fsn1', 6), ('hel1', 4)]),
            server('cheapest', 'x86', [location('nbg1')], [('nbg1', 3)])])
        result = self.shell('pv_hetzner_types', input=json.dumps(fixtures))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = result.stdout.splitlines()
        self.assertTrue(rows[0].startswith('cheapest|'), rows)
        self.assertTrue(rows[1].startswith('usable|'), rows)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1].split('|')[5:], ['4', 'x86', '2', 'true'])
        result = self.shell('pv_hetzner_locations usable', input=json.dumps(fixtures))
        self.assertEqual(result.stdout.splitlines(), ['hel1|4', 'fsn1|6'])
        result = self.shell('pv_hetzner_types', input=json.dumps({'server_types': fixtures['server_types'][:4]}))
        self.assertEqual(result.stdout, '')
        source = (ROOT / 'scripts/init-hetzner.sh').read_text()
        self.assertLess(source.index('SERVER_TYPE='), source.index('LOCATION='))
        self.assertIn('currently has no capacity', source)
        self.assertIn('architecture=${_type_arch:-x86}', source)

    def test_08_digitalocean_capacity_rows(self):
        fixtures = {'sizes': [dict(slug=slug, available=available, memory=2048,
                                 vcpus=2, disk=40, transfer=2, price_monthly=12, regions=regions)
                              for slug, available, regions in (
                                  ('s-2vcpu-2gb', True, ['fra1']),
                                  ('unavailable', False, ['fra1']), ('empty', True, []))]}
        result = self.shell('pv_digitalocean_sizes', input=json.dumps(fixtures))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['s-2vcpu-2gb|2|2048|40|2|12|fra1'])
        source = (ROOT / 'scripts/init-digitalocean.sh').read_text()
        self.assertLess(source.index('SIZE='), source.index('REGION='))
        self.assertNotIn('/datacenters', source)

    def test_08_confirm_enter_and_eof(self):
        for answer, status in (('\n', 0), ('y\n', 0), ('n\n', 10), ('r\n', 1), ('', 10)):
            with self.subTest(answer=answer):
                result = self.shell('_beep() { :; }; pv_confirm_create "Name:|fixture"', input=answer)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertIn('[Y/n/r]', result.stderr)
        result = self.shell('_beep() { :; }; _PV_TTY_IN=/dev/fd/9; pv_confirm_create "Name:|fixture"')
        self.assertEqual(result.returncode, 10)

    def test_08_rejected_create_signals_without_retry(self):
        self.stub('curl', 'cat >/dev/null; printf \'{"error":{"message":"unsupported location for server type"}}\\n422\'')
        result = self.shell('PV_LABEL=Fixture; PV_API=http://stub.invalid; PV_TOKEN=fixture; '
                            'pv_create_server /servers "{}" .server.id .server.ip; rc=$?; '
                            'printf "REJECTED:%s" "$PV_CREATE_REJECTED"; exit "$rc"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('REJECTED:true', result.stdout)
        self.assertIn('unsupported location', result.stderr)
        for provider in ('hetzner', 'digitalocean'):
            source = (ROOT / f'scripts/init-{provider}.sh').read_text()
            self.assertRegex(source, r'(?m)^pv_create_server[\s\S]+PV_CREATE_REJECTED[\s\S]+continue')

    def test_08_create_persistence_failure_stops(self):
        self.stub('curl', 'cat >/dev/null; printf \'{"server":{"id":77},"droplet":{"id":77}}\\n201\'')
        for provider, endpoint in (('hetzner', '/servers'), ('digitalocean', '/droplets')):
            with self.subTest(provider=provider):
                source = (ROOT / f'scripts/init-{provider}.sh').read_text()
                match = re.search(r'^((?:if )?pv_create_server .*?^done)$', source, re.M | re.S)
                self.assertIsNotNone(match)
                code = '''set -e
PV_LABEL=Fixture; PV_API=http://stub.invalid; PV_TOKEN=fixture; PV_ID_KEY=FIXTURE_ID
_HOST_FINGERPRINT=SHA256:fixture; _JQ_IP='.server.ip // empty'
_server_body='{}'; _droplet_body='{}'; _images_file="$TMPDIR/unused"
upsert_env_local() { return 1; }
upsert_env() { return 0; }
while true; do
''' + match[1] + '\nprintf CONTINUED'
                result = self.shell(code)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('CONTINUED', result.stdout)

    def test_08_provider_reselection_and_uncertain_stop(self):
        for provider, field, endpoint, id_field in (
                ('hetzner', 'server_types', '/servers', 'server'),
                ('digitalocean', 'sizes', '/droplets', 'droplet')):
            for uncertain in (False, True):
                with self.subTest(provider=provider, uncertain=uncertain):
                    for path in ('gets', 'posts', '.env', '.env.local'):
                        (self.root / path).unlink(missing_ok=True)
                    source = (ROOT / f'scripts/init-{provider}.sh').read_text()
                    start = source.index('while true; do', source.index('pv_resume_saved_server'))
                    end = source.index('SERVER_ID="$PV_SERVER_ID"' if provider == 'hetzner' else 'DROPLET_ID="$PV_SERVER_ID"', start)
                    loop = source[start:end]
                    plan = (dict(server_types=[dict(name='usable', architecture='x86', memory=2, cores=2, disk=40,
                                cpu_type='shared', locations=[dict(id=1, name='fsn1', available=True,
                                recommended=False, deprecation=None)], prices=[dict(location='fsn1',
                                price_monthly=dict(gross='4'))])]) if provider == 'hetzner' else
                            dict(sizes=[dict(slug='s-2vcpu-2gb', memory=2048, vcpus=2, disk=40,
                                transfer=2, available=True, price_monthly=12, regions=['fra1'])]))
                    (self.root / 'plans.json').write_text(json.dumps(plan))
                    images = dict(images=[dict(name='debian-13', slug='debian-13-x64', os_flavor='debian',
                                  distribution='Debian', description='Debian 13', public=True,
                                  status='available', regions=['fra1'])])
                    if provider == 'digitalocean':
                        images['images'].append(dict(images['images'][0], slug='debian-13-arm64'))
                    (self.root / 'images.json').write_text(json.dumps(images))
                    self.stub('curl', '''cat > "$TMPDIR/body.json"
if [ -e "$TMPDIR/posts" ]; then
  echo again >> "$TMPDIR/posts"
  printf '{"server":{"id":77},"droplet":{"id":77}}\\n201'
else
  echo first > "$TMPDIR/posts"
  if [ "$UNCERTAIN" = true ]; then printf '\\n000'; exit 28; fi
  printf '{"error":{"message":"unsupported location for server type"}}\\n422'
fi''')
                    prefix = '''set -euo pipefail
ENV_FILE="$TMPDIR/.env"; ENV_CONFIG="$TMPDIR/.env.config"; ENV_LOCAL="$TMPDIR/.env.local"
PV_LABEL=Fixture; PV_API=http://stub.invalid; PV_TOKEN=fixture; PV_ID_KEY=FIXTURE_ID
_JQ_IP='.server.ip // empty'
pv_api_get() {
  case "$1" in
    /server_types*|/sizes*) echo lookup >> "$TMPDIR/gets"; cat "$TMPDIR/plans.json";;
    /images*) cat "$TMPDIR/images.json";;
    *) return 99;;
  esac
}
pv_select_ssh_key() { SSH_KEY_ID=1; SSH_KEY_NAME=fixture; PV_KEY_FP=fixture; }
pv_match_local_privkey() { _matched_privkey=""; }
validate_ssh_private_key() { :; }
pv_prompt_server_name() { PV_SERVER_NAME=fixture; }
pv_gen_host_keys() { _USER_DATA=fixture; _HOST_FINGERPRINT=SHA256:fixture; }
_beep() { :; }
'''
                    result = self.shell(prefix + loop, input='\n\n\n\n\n\n', UNCERTAIN=str(uncertain).lower())
                    self.assertEqual(result.returncode, 11 if uncertain else 0, result.stdout + result.stderr)
                    self.assertEqual(len((self.root / 'gets').read_text().splitlines()), 1 if uncertain else 2)
                    self.assertEqual(len((self.root / 'posts').read_text().splitlines()), 1 if uncertain else 2)
                    if not uncertain:
                        self.assertIn('unsupported location', result.stderr)
                        body = json.loads((self.root / 'body.json').read_text())
                        self.assertEqual(body.get('location', body.get('region')), 'fsn1' if provider == 'hetzner' else 'fra1')
                        self.assertEqual(body['image'], 'debian-13' if provider == 'hetzner' else 'debian-13-x64')

    def test_12_pipe_input_keeps_caller_cleanup(self):
        result = self.shell('''trap 'printf CALLER_EXIT >&2' EXIT
trap 'printf CALLER_INTERRUPT >&2' INT
read_secret value
[ "$value" = literal ] || exit 91
trap -p INT
''', input='literal\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CALLER_EXIT', result.stderr)
        self.assertIn('CALLER_INTERRUPT', result.stdout)
        self.assertNotIn('literal', result.stdout + result.stderr)

    def test_12_masked_input_pty(self):
        cases = [('paste', b'a b\\*%' + b'x' * 2048 + b'\n', 'a b\\*%' + 'x' * 2048, 0),
                 ('backspace', b'\x7faX\x08bY\x7f\n', 'ab', 0),
                 ('empty', b'\n', '', 0), ('eof', b'partial\x04', 'partial', 1),
                 ('interrupt', b'\x03', '', 130)]
        for name, payload, expected, status in cases:
            with self.subTest(case=name):
                master, slave = pty.openpty()
                state = "import termios; s=termios.tcgetattr(0); s[3]&=~getattr(termios, 'PENDIN', 0); print(repr(s))"
                code = self.base + f'terminal_state() {{ python3 -c "{state}"; }}; before=$(terminal_state); ' + \
                    'read_secret value; rc=$?; after=$(terminal_state); ' + \
                    '[ "$before" = "$after" ] || exit 90; [ "$value" = "$EXPECTED" ] || exit 91; printf "RESULT:%s" "$rc"'
                def controlling_terminal():
                    os.setsid()
                    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

                proc = subprocess.Popen(['/bin/bash', '-c', code], stdin=slave, stdout=slave, stderr=slave,
                                        env=dict(self.env, EXPECTED=expected), cwd=self.root,
                                        preexec_fn=controlling_terminal)
                output = b''
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and proc.poll() is None:
                    if not termios.tcgetattr(slave)[3] & termios.ECHO:
                        break
                    select.select([], [], [], 0.01)
                os.set_blocking(master, False)
                pending = payload
                while time.monotonic() < deadline:
                    ready, writable, _ = select.select([master], [master] if pending else [], [], 0.05)
                    if writable:
                        try:
                            pending = pending[os.write(master, pending):]
                        except BlockingIOError:
                            pass
                    if ready:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output += chunk
                    elif proc.poll() is not None:
                        break
                if proc.poll() is None:
                    proc.kill()
                rc = proc.wait()
                os.close(master)
                os.close(slave)
                self.assertEqual(rc, 0, output)
                self.assertIn(f'RESULT:{status}'.encode(), output)
                self.assertNotIn(b'partial', output)
                self.assertNotIn(b'a b', output)
                if expected:
                    self.assertIn(b'*', output)
                self.assertRegex(output, rb'^[*\x08 \r\n]*RESULT:[0-9]+$')


if __name__ == '__main__':
    unittest.main(verbosity=2)

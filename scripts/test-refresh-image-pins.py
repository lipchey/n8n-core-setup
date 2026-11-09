import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUB = r'''
import json
import os
import sys

args = sys.argv[1:]
url = args[-1]
with open(os.environ["CURL_CALLS"], "a") as log:
    log.write(json.dumps(args) + "\n")
status = "200"
if "hub.docker.com/v2/repositories/" in url:
    status = os.environ.get("TAGS_HTTP", "200")
    if "page=2" in url:
        status = os.environ.get("SECOND_PAGE_HTTP", status)
    tag = "16.99-alpine" if "/library/postgres/" in url else "2.99.0" if "/n8nio/n8n/" in url else "2026.99.0"
    tags = [{"name": tag, "digest": "sha256:" + "a" * 64}]
    if "/n8nio/n8n/" in url:
        tags += [{"name": "2.100.0", "digest": "sha256:" + "b" * 64},
                 {"name": "next", "digest": "sha256:" + "b" * 64}]
        if os.environ.get("STABLE_NO_MATCH"):
            tags[0]['digest'] = "sha256:" + "c" * 64
    body = json.dumps({"results": [] if os.environ.get("TAGS_EMPTY") else tags,
                       "next": "page2" if os.environ.get("SECOND_PAGE_HTTP") and "page=1" in url else None})
elif url.startswith("https://auth.docker.io/token?"):
    status = os.environ.get("TOKEN_HTTP", "200")
    body = '{"token":"stub-token"}'
elif "/manifests/" in url:
    status = os.environ.get("MANIFEST_HTTP", "200")
    if url.endswith('/n8nio/n8n/manifests/stable'):
        status = os.environ.get('STABLE_HTTP', status)
    if os.environ.get("CURL_ERROR"):
        sys.exit(7)
    body = "HTTP/1.1 " + status + "\r\nDocker-Content-Digest: sha256:" + "a" * 64 + "\r\n"
    if url.endswith('/stable') and os.environ.get('STABLE_EMPTY'):
        body = 'HTTP/1.1 200\r\n'
else:
    sys.exit(99)
if int(status) >= 400 and any(arg.startswith("-") and "f" in arg for arg in args):
    sys.exit(22)
sys.stdout.write(body)
if "-w" in args:
    sys.stdout.write("\n" + status)
'''


class RefreshImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".test-image-pins-", dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "n8n").mkdir()
        self.script = self.root / "scripts/refresh-image-pins.sh"
        self.script.write_text((ROOT / "scripts/refresh-image-pins.sh").read_text()
                               .replace(">/dev/tty", '>"$REFRESH_TTY_OUT"')
                               .replace("</dev/tty", '<"$REFRESH_TTY_IN"'))
        self.compose = self.root / "n8n/docker-compose.yml"
        self.compose.write_text('services:\n' + ''.join(
            f'  {service}:\n    image: {image}@sha256:{"0" * 64}\n'
            for service, image in (('postgres', 'postgres:16.0-alpine'),
                                   ('n8n', 'n8nio/n8n:2.0.0'),
                                   ('cloudflared', 'cloudflare/cloudflared:2025.1.0'))))
        self.original = self.compose.read_text()
        binary = self.root / "bin"
        binary.mkdir()
        curl = binary / "curl"
        curl.write_text(f"#!{sys.executable}\n" + STUB)
        curl.chmod(0o755)
        self.calls = self.root / "curl-calls"
        self.tty = self.root / "tty"
        self.env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}", CURL_CALLS=str(self.calls),
                        REFRESH_TTY_IN="/dev/stdin", REFRESH_TTY_OUT=str(self.tty))

    def run_refresh(self, *flags, answer=None, **environment):
        env = dict(self.env, **environment)
        if answer is None:
            env["REFRESH_TTY_IN"] = str(self.root / "closed-terminal")
        result = subprocess.run(["bash", str(self.script), *flags], env=env,
                                input=(answer or b"").decode(), capture_output=True,
                                text=True, timeout=20, start_new_session=True)
        output = result.stdout + result.stderr
        if self.tty.exists():
            output += self.tty.read_text()
        return result.returncode, output

    def assert_updated(self):
        self.assertIn("n8nio/n8n:2.99.0@sha256:" + "a" * 64, self.compose.read_text())

    def test_hub_image_and_head_requests(self):
        image = re.search(r"image: (\S*n8nio/n8n:\S+)", self.original)[1]
        self.assertTrue(image.startswith("n8nio/n8n:"), image)
        status, output = self.run_refresh("--dry-run")
        self.assertEqual(status, 0, output)
        requests = [json.loads(line) for line in self.calls.read_text().splitlines()]
        manifests = [args for args in requests if "/manifests/" in args[-1]]
        self.assertEqual(len(manifests), 4)
        for args in manifests:
            self.assertIn("-I", args)
            self.assertTrue(args[-1].startswith("https://registry-1.docker.io/"), args[-1])
        self.assertEqual(self.original, self.compose.read_text())

    def test_n8n_picks_numeric_stable_even_when_next_has_the_highest_version(self):
        status, output = self.run_refresh('--yes')
        self.assertEqual(status, 0, output)
        self.assert_updated()
        self.assertNotIn('n8nio/n8n:2.100.0', self.compose.read_text())

    def test_n8n_stable_lookup_failures_never_fall_back_to_the_highest_version(self):
        for environment, reason in (({'STABLE_HTTP': '503'}, 'HTTP 503'),
                                    ({'STABLE_EMPTY': '1'}, 'digest'),
                                    ({'STABLE_NO_MATCH': '1'}, 'numeric tag')):
            with self.subTest(environment=environment):
                self.compose.write_text(self.original)
                status, output = self.run_refresh('--yes', **environment)
                self.assertEqual(status, 1, output)
                self.assertIn('stable', output)
                self.assertIn(reason, output)
                original_n8n = next(line for line in self.original.splitlines() if 'n8nio/n8n:' in line)
                self.assertIn(original_n8n, self.compose.read_text())

    def test_registry_bearer_is_not_in_curl_arguments(self):
        status, output = self.run_refresh('--dry-run')
        self.assertEqual(status, 0, output)
        self.assertNotIn('stub-token', self.calls.read_text())

    def test_http_failure_reasons(self):
        for endpoint in ("MANIFEST_HTTP", "TOKEN_HTTP"):
            for code in ("429", "503"):
                with self.subTest(endpoint=endpoint, code=code):
                    status, output = self.run_refresh("--yes", **{endpoint: code})
                    self.assertEqual(status, 1, output)
                    reason = "rate limited (HTTP 429)" if code == "429" else "failed (HTTP 503)"
                    self.assertIn(f"digest lookup {reason} — skipped", output)
                    self.assertEqual(self.original, self.compose.read_text())

    def test_transport_failure_skips_pins(self):
        status, output = self.run_refresh("--yes", CURL_ERROR="1")
        self.assertEqual(status, 1, output)
        self.assertEqual(self.original, self.compose.read_text())

    def test_tag_listing_http_failures_report_status_without_changing_pins(self):
        for endpoint in ("TAGS_HTTP", "SECOND_PAGE_HTTP"):
            for code in ("429", "503"):
                with self.subTest(endpoint=endpoint, code=code):
                    status, output = self.run_refresh("--yes", **{endpoint: code})
                    self.assertEqual(status, 1, output)
                    self.assertIn("tag listing", output)
                    self.assertIn("HTTP " + code, output)
                    self.assertNotIn("no tags matched", output)
                    self.assertEqual(self.original, self.compose.read_text())

    def test_successful_empty_tag_listing_keeps_no_match_reason(self):
        status, output = self.run_refresh("--yes", TAGS_EMPTY="1")
        self.assertEqual(status, 1, output)
        self.assertIn("no tags matched filter", output)
        self.assertEqual(self.original, self.compose.read_text())

    def test_first_run_enter_and_y_apply_without_warning(self):
        for answer in (b"\n", b"y\n"):
            with self.subTest(answer=answer):
                self.compose.write_text(self.original)
                status, output = self.run_refresh("--first-run", answer=answer)
                self.assertEqual(status, 0, output)
                self.assertIn("Apply these changes? [Y/n]", output)
                self.assertNotIn("DB migrations", output)
                self.assert_updated()

    def test_first_run_decline_eof_and_closed_terminal_preserve_pins(self):
        for answer in (b"n\n", b"123\n", b" \n", b"", b"y", None):
            with self.subTest(answer=answer):
                self.run_refresh("--first-run", answer=answer)
                self.assertEqual(self.original, self.compose.read_text())

    def test_standalone_defaults_no_and_warns_briefly(self):
        status, output = self.run_refresh(answer=b"\n")
        self.assertEqual(status, 0, output)
        self.assertIn("Apply these changes? [y/N]", output)
        self.assertIn("n8nio/n8n", output)
        self.assertIn("library/postgres", output)
        self.assertIn("DB migrations are one-way", output)
        self.assertIn("npm run backup-database", output)
        self.assertIn("docs/operations.md#image-updates-and-rollback", output)
        self.assertNotIn("Pre-deploy checklist:", output)
        self.assertNotIn("Rollback procedure", output)
        self.assertEqual(self.original, self.compose.read_text())

    def test_yes_and_dry_run_keep_their_behavior(self):
        status, output = self.run_refresh("--dry-run")
        self.assertEqual(status, 0, output)
        self.assertNotIn("Apply these changes?", output)
        self.assertEqual(self.original, self.compose.read_text())
        status, output = self.run_refresh("--yes")
        self.assertEqual(status, 0, output)
        self.assertNotIn("Apply these changes?", output)
        self.assert_updated()

    def test_wizard_passes_first_run_only_for_uninitialized_trees(self):
        source = (ROOT / "scripts/initialize.sh").read_text()
        detection = re.search(r"^_is_rerun=false\n.*_is_rerun=true$", source, re.M)
        self.assertIsNotNone(detection)
        self.assertLess(detection.start(), source.index('_image_choice=$(ask_yn'))
        block = source[source.index('_image_choice=$(ask_yn'):source.index('\n_failures=()')]
        for state in (None, ".env.config", ".env", ".env.sops.yaml"):
            with self.subTest(state=state):
                if state:
                    (self.root / state).touch()
                program = '\n'.join([
                    'ROOT_DIR="$1"; SCRIPT_DIR="$ROOT_DIR/scripts"',
                    'ENV_CONFIG="$ROOT_DIR/.env.config"; ENV_FILE="$ROOT_DIR/.env"',
                    detection[0], 'ask_yn() { printf y; }',
                    'bash() { printf "CALL:%s\\n" "$*"; }', block,
                ])
                result = subprocess.run(["bash", "-c", program, "test", str(self.root)],
                                        capture_output=True, text=True, check=True)
                call = next(line for line in result.stdout.splitlines() if line.startswith("CALL:"))
                self.assertEqual("--first-run" in call, state is None, call)
                if state:
                    (self.root / state).unlink()


if __name__ == "__main__":
    unittest.main()

import runpy
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


root = Path(__file__).resolve().parents[1]
generator = root / "scripts/generate-setup-docs.py"
assert generator.is_file(), "Setup documentation generator is missing"
render = runpy.run_path(str(generator))["render"]
fixture = '''section_header "Phase 1/2 — Config"
section_header "Tokens"
NAME=$(prompt_value \\
  "Name (required)" "${NAME:-$(basename "$ROOT_DIR")}" "false" "false")
TOKEN=$(prompt_value "Token" "" "true" "true")
DISPLAY_TZ=$(prompt_timezone)
answer=$(ask_yn "Continue? [Y/n] " "y")
read_secret token
echo "▶  Step 1/4: OS setup ..."
'''
table = render(fixture)
assert "Name (required)" in table and "${NAME:-$(basename $ROOT_DIR)}" in table
assert "| Token | — | yes | yes |" in table
assert "| Continue? [Y/n]  | `y` | no | no |" in table
assert "City or timezone (e.g. Berlin, New York, Europe/Berlin)" in table
assert "Create private GitHub repository confirmation" not in table
assert 'Phase 1/2 — Config' in table
assert table.index("Phase 1/2") < table.index("Step 1/4")
assert "read_secret token" in table
assert '| Tokens |' in table
try:
    render('value=$(prompt_value "Name" "" "maybe")')
except ValueError:
    pass
else:
    raise AssertionError("Unsupported prompt signature must fail")

with tempfile.TemporaryDirectory(prefix=".setup-docs-test-", dir=root) as directory:
    copy = Path(directory)
    (copy / "scripts").mkdir()
    (copy / "docs").mkdir()
    shutil.copyfile(generator, copy / "scripts" / generator.name)
    (copy / "scripts/initialize.sh").write_text(fixture)
    command = [sys.executable, str(copy / "scripts" / generator.name)]
    subprocess.run(command, check=True, capture_output=True)
    subprocess.run(command + ["--check"], check=True, capture_output=True)
    document = copy / "docs/setup-prompts.md"
    document.write_text(document.read_text().replace("Name (required)", "Stale name"))
    stale = subprocess.run(command + ["--check"], capture_output=True, text=True)
    assert stale.returncode == 1 and "stale" in stale.stderr, stale
    subprocess.run(command, check=True, capture_output=True)
    (copy / "scripts/initialize.sh").write_text(fixture.replace("OS setup", "New step"))
    assert subprocess.run(command + ["--check"], capture_output=True).returncode == 1

print("test-setup-docs: parser, generation, stale document and source drift passed")

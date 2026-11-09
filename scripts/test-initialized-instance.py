import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    if os.environ.get('N8N_INITIALIZED_INSTANCE_TEST') == '1':
        print('Initialized-instance recursion guard')
        return
    with tempfile.TemporaryDirectory(prefix='.test-initialized-instance-', dir=ROOT) as directory:
        root = Path(directory) / 'tree'
        root.mkdir()
        env = dict(os.environ, HOME=str(Path(directory) / 'home'),
                   GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                   GIT_ALLOW_PROTOCOL='file', N8N_INITIALIZED_INSTANCE_TEST='1',
                   npm_config_update_notifier='false', npm_config_offline='true')
        files = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z',
                                         '--cached', '--others', '--exclude-standard']).split(b'\0')
        for name in files:
            if not name:
                continue
            relative = Path(os.fsdecode(name))
            if relative.name.startswith('.env') and relative.name not in ('.env.example', '.env.developer.example'):
                continue
            source = ROOT / relative
            if source.is_file():
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        initialize = (root / 'scripts/initialize.sh').read_text()
        age_writer = re.search(r'^_ensure_age_key\(\) \{\n.*?^\}', initialize, re.M | re.S)[0]
        code = f'''set -e
source scripts/lib/prompts.sh
ROOT_DIR="$PWD"; PROJECT_NAME=instance-fixture; GITHUB_REPO=instance-owner/instance-fixture
age-keygen() {{ if [ "$1" = -y ]; then echo age1instancefixture; else printf 'fixture\\n' > "$2"; fi; }}
{age_writer}
_ensure_age_key
'''
        subprocess.run(['bash', '-c', code], cwd=root, env=env, check=True, capture_output=True, text=True)
        (root / '.env.config').write_text('PROJECT_NAME=instance-fixture\nGITHUB_REPO=instance-owner/instance-fixture\nGITHUB_BRANCH=main\nDISPLAY_TZ=UTC\nDEVELOPER_EMAIL=fixture@example.invalid\nN8N_PROJECTS_DOMAIN=fixture.example.invalid\n')
        (root / '.env.sops.yaml').write_text('fixture-encrypted-content\n')
        with (root / '.gitignore').open('a') as ignore:
            ignore.write('\ninstance-runtime/\n')
        compose = root / 'n8n/docker-compose.yml'
        compose.write_text(re.sub(r'(image: \S+?:)[^\s]+', r'\g<1>99.0@sha256:' + 'b' * 64, compose.read_text()))
        for args in (['init', '-q', '-b', 'main'], ['add', '.']):
            subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', *args], cwd=root, env=env, check=True, capture_output=True)
        result = subprocess.run(['npm', 'run', 'test:unit'], cwd=root, env=env,
                                capture_output=True, text=True, timeout=600)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'Initialized-instance recursion guard' in result.stdout, result.stdout
        print('Initialized-instance unit suite passed')


if __name__ == '__main__':
    main()

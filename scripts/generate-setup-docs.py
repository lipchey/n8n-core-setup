import re
import shlex
import sys
from pathlib import Path


def cell(value):
    return value.replace("|", "&#124;").replace("<", "&lt;").replace(">", "&gt;")


def arguments(source, start):
    quote = None
    escaped = False
    depth = 0
    for index in range(start, len(source)):
        char = source[index]
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote:
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            if depth == 0:
                return shlex.split(source[start:index].replace("\\\n", ""))
            depth -= 1
    raise ValueError("Unterminated prompt call")


def render(source):
    lines = [
        "# Initialization steps and prompts", "",
        "Generated from [the initializer](../scripts/initialize.sh); do not edit this page by hand.",
        "Regenerate with `python3 scripts/generate-setup-docs.py` from the repository root.", "",
        "Headings and helper calls appear in source order, including conditional branches; this is not a runtime trace.",
        "Defaults are shell expressions, shown without evaluating them or reading local secrets.",
        "Blank allowed means the helper accepts an empty value; it does not mean the resulting deployment will work.",
        "The repository-name dialog inside `create_private_github_repo` is not extracted; submitting it creates a private repository.",
        "For a recommended first run and conditional inputs, see [setup](setup.md).", "",
        "## Phase and action headings", "", "| Source line | Heading |", "| --- | --- |",
    ]
    for number, line in enumerate(source.splitlines(), 1):
        heading = re.fullmatch(r'\s*(?:echo "((?:  Phase \d+/\d+|▶).*?)"|section_header "([^"]+)")', line)
        if heading:
            lines.append(f"| {number} | {cell((heading[1] or heading[2]).strip())} |")
    lines += ["", "## Helper prompts", "",
              "On reruns, valid saved defaults may be accepted without a prompt.", "",
              "| Source line | Prompt | Default expression | Hidden | Blank allowed |",
              "| --- | --- | --- | --- | --- |"]
    for match in re.finditer(r'\$\((prompt_value|ask_yn|prompt_timezone)(?:\s+|(?=\)))', source):
        args = arguments(source, match.end())
        if match[1] == "prompt_value":
            if not 2 <= len(args) <= 6 or any(arg not in {"true", "false"} for arg in args[2:4]):
                raise ValueError("Unsupported prompt_value signature")
            args += ["false"] * max(0, 4 - len(args))
            label, default, hidden, blank = args[:4]
        elif match[1] == "ask_yn":
            if not 1 <= len(args) <= 2 or (len(args) == 2 and args[1] not in {"y", "n"}):
                raise ValueError("Unsupported ask_yn signature")
            label, default = args[0], args[1] if len(args) == 2 else "n"
            hidden = blank = "false"
        else:
            label = "City or timezone (e.g. Berlin, New York, Europe/Berlin)"
            default = "saved DISPLAY_TZ or machine timezone, otherwise UTC"
            hidden = blank = "false"
        number = source.count("\n", 0, match.start()) + 1
        default = f"`{cell(default)}`" if default else "—"
        lines.append(f"| {number} | {cell(label)} | {default} | {'yes' if hidden == 'true' else 'no'} | {'yes' if blank == 'true' else 'no'} |")
    lines += ["", "## Direct input inventory", "",
              "These reads bypass the helpers. Only their statements and order are checked; prompt wording,",
              "defaults and conditional meaning require manual review. Provider, Cloudflare, image-refresh,",
              "retry-helper and environment-test dialogs are outside this table.", "",
              "| Source line | Read statement |", "| --- | --- |"]
    for number, line in enumerate(source.splitlines(), 1):
        if re.search(r'\bread_secret\s+', line) or (re.search(r'\bread -', line) and ("</dev/tty" in line or line.strip() == "read -r CONFIRM")):
            lines.append(f"| {number} | `{cell(line.strip())}` |")
    return "\n".join(lines) + "\n"


def main():
    if sys.argv[1:] not in ([], ["--check"]):
        raise SystemExit("Usage: python3 scripts/generate-setup-docs.py [--check]")
    root = Path(__file__).resolve().parents[1]
    document = root / "docs/setup-prompts.md"
    expected = render((root / "scripts/initialize.sh").read_text())
    if sys.argv[1:]:
        if not document.is_file() or document.read_text() != expected:
            print("Setup table is stale; run python3 scripts/generate-setup-docs.py", file=sys.stderr)
            return 1
        print("Setup table is current")
    else:
        document.write_text(expected)
        print("Wrote docs/setup-prompts.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())

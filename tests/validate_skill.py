import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SKILL_MD = ROOT / "module-test" / "SKILL.md"


def main():
    if not SKILL_MD.is_file():
        print("FAIL: missing SKILL.md")
        return 1
    text = SKILL_MD.read_text(encoding="utf-8")
    if not text.startswith("---"):
        print("FAIL: missing frontmatter")
        return 1
    match = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    if not match:
        print("FAIL: invalid frontmatter")
        return 1
    front = match.group(1)
    name_match = re.search(r"^name:\s*(.+)$", front, re.MULTILINE)
    if not name_match:
        print("FAIL: missing name")
        return 1
    name = name_match.group(1).strip()
    if not re.fullmatch(r"[a-z0-9-]+", name) or name.startswith("-") or name.endswith("-") or "--" in name:
        print(f"FAIL: invalid name {name}")
        return 1
    desc_match = re.search(r"^description:\s*(.+)$", front, re.MULTILINE)
    if not desc_match or "<" in desc_match.group(1) or ">" in desc_match.group(1):
        print("FAIL: invalid description")
        return 1
    print("PASS: skill frontmatter valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())

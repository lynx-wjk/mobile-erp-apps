param(
  [string]$Repo = "C:\Users\budic\Downloads\android\inventory_control_apps"
)

$ErrorActionPreference = "Stop"
Set-Location $Repo

$py = @'
from pathlib import Path
import os
import re
import subprocess
import sys

ROOT = Path(".").resolve()
FEATURES = ROOT / "lib" / "features"

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")

def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")

def relative_import_for(file_path: Path) -> str:
    target = ROOT / "lib" / "core" / "ui" / "app_ui.dart"
    return os.path.relpath(target, file_path.parent).replace("\\", "/")

def add_app_ui_import_if_needed(file_path: Path, text: str) -> str:
    if "AppUi." not in text or "core/ui/app_ui.dart" in text:
        return text
    import_line = f"import '{relative_import_for(file_path)}';\n"
    lines = text.splitlines(True)
    last_import_idx = -1
    for i, line in enumerate(lines):
        if line.strip().startswith("import "):
            last_import_idx = i
    if last_import_idx >= 0:
        lines.insert(last_import_idx + 1, import_line)
        return "".join(lines)
    return import_line + text

def patch_text(text: str) -> tuple[str, bool]:
    original = text
    text = re.sub(
        r"Theme\.of\(context\)\s*\.colorScheme\s*\.outline(?!Variant)",
        "AppUi.mutedText(context, 0.92)",
        text,
    )
    text = re.sub(
        r"Theme\.of\(context\)\s*\.colorScheme\s*\.onSurface\s*\.withOpacity\((?:0\.45|0\.50|0\.5|0\.55|0\.58|0\.60|0\.6|0\.65|0\.70|0\.7|0\.75)\)",
        "AppUi.mutedText(context, 0.90)",
        text,
    )
    text = re.sub(
        r"\bColors\.grey(?:\.shade(?:500|600|700))?",
        "AppUi.mutedText(context, 0.90)",
        text,
    )
    return text, text != original

changed_files = []
for path in sorted(FEATURES.rglob("*.dart")):
    if not path.is_file():
        continue
    text = read(path)
    patched, changed = patch_text(text)
    if not changed:
        continue
    patched = add_app_ui_import_if_needed(path, patched)
    if "AppUi.mutedText(context, 0.92)Variant" in patched:
        sys.exit(f"ERROR: broken outlineVariant replacement in {path}")
    write(path, patched)
    changed_files.append(path)

if not changed_files:
    print("NO_UI_CONTRAST_CHANGES")
else:
    print("PATCHED_FILES=" + str(len(changed_files)))
    for path in changed_files:
        print(str(path.relative_to(ROOT)).replace("\\", "/"))
    subprocess.run(["dart", "format", *[str(p.relative_to(ROOT)) for p in changed_files]], check=True)
'@

$py | python -

flutter analyze --no-fatal-infos --no-fatal-warnings

git diff --stat
git diff -- lib/features

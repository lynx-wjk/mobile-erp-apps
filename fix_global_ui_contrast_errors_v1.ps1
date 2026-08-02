param(
  [string]$Repo = "C:\Users\budic\Downloads\android\inventory_control_apps"
)

$ErrorActionPreference = "Stop"
Set-Location $Repo

$files = git diff --name-only -- lib/features | Where-Object { $_ -like "*.dart" }
if (-not $files -or $files.Count -eq 0) {
  Write-Host "NO_CHANGED_FEATURE_DART_FILES"
  exit 0
}

$env:PATCH_FILES = ($files -join "`n")

$py = @'
import os
import re
from pathlib import Path

files = [x.strip() for x in os.environ.get("PATCH_FILES", "").splitlines() if x.strip()]
patched = []

for name in files:
    p = Path(name)
    text = p.read_text(encoding="utf-8-sig")
    original = text

    # v1 mistake:
    #   Colors.grey[600] -> AppUi.mutedText(context, 0.90)[600]
    # AppUi.mutedText returns Color, not MaterialColor, so remove shade indexing.
    text = re.sub(
        r"AppUi\.mutedText\(context,\s*([0-9.]+)\)\s*\[\s*\d+\s*\]!?",
        r"AppUi.mutedText(context, \1)",
        text,
    )

    # v1 mistake: AppUi.mutedText(context) inside const widgets/styles.
    # Make changed Text/TextStyle non-const in patched files. This is safe and narrow to currently changed files.
    if "AppUi.mutedText(context" in text:
        text = text.replace("const TextStyle(", "TextStyle(")
        text = text.replace("const Text(", "Text(")
        text = text.replace("const Icon(", "Icon(")
        text = text.replace("const SelectableText(", "SelectableText(")

    # Cleanup null-aware operator that v1 inherited from old outline chain.
    text = text.replace("AppUi.mutedText(context, 0.92)?.withOpacity", "AppUi.mutedText(context, 0.92).withOpacity")
    text = text.replace("AppUi.mutedText(context, 0.90)?.withOpacity", "AppUi.mutedText(context, 0.90).withOpacity")

    if text != original:
        p.write_text(text, encoding="utf-8", newline="\n")
        patched.append(name)

print("FIXED_FILES=" + str(len(patched)))
for name in patched:
    print(name)
'@

$py | python -

# Format from PowerShell, not Python subprocess.
dart format @files

git diff --check
flutter analyze --no-fatal-infos --no-fatal-warnings

git diff --stat
git diff -- lib/features

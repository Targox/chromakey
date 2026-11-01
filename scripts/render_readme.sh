#!/bin/zsh
set -eu
cd "${0:A:h}/.."
python3 - <<'PY'
from pathlib import Path
p=Path('build/ReadmeRenderer.swift')
s=Path('main.swift').read_text().split('final class AppDelegate:')[0]
p.write_text(s+'\n'+Path('scripts/render_readme.swift').read_text())
PY
swift build/ReadmeRenderer.swift "$PWD" "$@"

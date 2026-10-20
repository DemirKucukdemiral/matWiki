#!/usr/bin/env python3
"""Read-only, dependency-free check; never installs anything."""
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys


def main():
    root = Path(os.environ.get('MATWIKI_HOME', Path(__file__).resolve().parents[1]))
    nvim = shutil.which('nvim')
    version = None
    if nvim:
        result = subprocess.run([nvim, '--version'], capture_output=True, text=True, timeout=10)
        match = re.search(r'NVIM v(\d+)\.(\d+)\.(\d+)', result.stdout)
        if match:
            version = tuple(map(int, match.groups()))
    tools = {
        name: shutil.which(name) for name in (
            'nvim', 'latexmk', 'pdflatex', 'lualatex', 'xelatex', 'python3', 'node',
            'pandoc', 'git', 'rg', 'texlab', 'pyright-langserver',
            'lua-language-server', 'typescript-language-server', 'clangd',
            'zathura', 'open' if platform.system() == 'Darwin' else 'xdg-open',
        )
    }
    report = {
        'platform': platform.system(), 'root': str(root),
        'neovim_version': '.'.join(map(str, version)) if version else None,
        'ready': bool(version and version >= (0, 12, 4)),
        'tools': tools,
        'vimtex_bundled': (root / 'vendor/vimtex/plugin/vimtex.vim').is_file(),
    }
    if '--json' in sys.argv:
        print(json.dumps(report, indent=2))
    else:
        print('MatWiki · dependency check\n')
        print(f"Platform: {report['platform']}")
        print(f"Neovim:   {report['neovim_version'] or 'not installed'} (requires 0.12.4+)")
        print(f"VimTeX:   {'bundled' if report['vimtex_bundled'] else 'missing'}\n")
        for name, path in tools.items():
            print(f'{name:28} {path or "not installed (optional)"}')
        print('\nNote editing needs only Neovim. PDF builds need latexmk and a TeX engine.')
        print('Markdown PDF export additionally needs Pandoc. Language servers are optional.')
        print('See README.md for macOS and Linux setup.')
    return 0 if report['ready'] and report['vimtex_bundled'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

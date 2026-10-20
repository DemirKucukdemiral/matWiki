#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

for suite in runner wiki latex mw; do
  printf '==> Running tests/%s.lua\n' "$suite"
  nvim --headless -u NONE -i NONE -n -l "tests/$suite.lua"
  printf '\n'
done

printf 'All MatWiki test suites passed.\n'

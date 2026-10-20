#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
TEST_STATE=$(mktemp -d "${TMPDIR:-/tmp}/matwiki-tests.XXXXXX")
trap 'rm -rf "$TEST_STATE"' EXIT HUP INT TERM
export NVIM_LOG_FILE="$TEST_STATE/nvim.log"

for suite in runner wiki latex mw ui; do
  printf '==> Running tests/%s.lua\n' "$suite"
  nvim --headless -u NONE -i NONE -n -l "tests/$suite.lua"
  printf '\n'
done

printf 'All MatWiki test suites passed.\n'

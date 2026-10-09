#!/usr/bin/env bash
# Seal fork-CI (Travis): run jQuery's real unit suite -- the QUnit browser
# suite at test/index.html -- in headless Chrome, after `npm test` (grunt
# default task, node 0.10) has built dist/jquery.js and dist/jquery.min.js.
#
# Invoked from .travis.yml as `bash test/seal-travis-qunit.sh`, as the last
# `script:` entry. It runs in its own bash process, so the Node 20 nvm switch
# below never leaks into the node 0.10 build.
#
# Prints one PASS/FAIL line per QUnit test plus a summary (see
# test/seal-browser-runner.js); exits non-zero if any test fails or the
# suite does not finish.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRIVER_DIR="$HOME/seal-driver"
PHP_LOG="$HOME/seal-php.log"
SUITE_URL="http://127.0.0.1:8000/test/index.html"

# "||"-separated exact "module: test" names the runner does not register
# (reported as SKIPPED). A non-empty SEAL_SKIP_TESTS in the environment
# replaces the defaults below, which are browser-environment failures in
# current headless Chrome, not jQuery bugs:
# - ajax: #14379 - jQuery.ajax() on unload: the fixture issues a synchronous
#   XHR from an unload handler; Chrome >= 80 blocks synchronous XHR during page
#   dismissal/unload (the request never reaches the server, status "error").
#   No command-line flag re-allows it in current Chrome (checked:
#   --{enable,disable}-blink-features / --{enable,disable}-features with
#   AllowSyncXHRInPageDismissal / ForbidSyncXHRInPageDismissal).
# - offset: fractions (see #7730 and #7885): Blink snaps layout offsets to
#   1/64 px, so a top of 1000 reads back as 999.984375.
# - core: document ready when jQuery loaded asynchronously (#13655): flaky in
#   current Chrome; the fixture (core/dynamic_ready.html) races ready of a
#   getScript-loaded jQuery copy against a 10s timer while a sibling iframe
#   hangs on dont_return.php (sleep 30); passed and failed on the same commit.
export SEAL_SKIP_TESTS="${SEAL_SKIP_TESTS:-ajax: #14379 - jQuery.ajax() on unload||offset: fractions (see #7730 and #7885)||core: document ready when jQuery loaded asynchronously (#13655)}"

test -f dist/jquery.js
test -f dist/jquery.min.js

# --- Node 20 for the puppeteer-core driver (nvm.sh is not `set -eu` safe) ---
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
set +eu
# shellcheck disable=SC1091
source "$NVM_DIR/nvm.sh"
nvm install 20 && nvm use 20
nvm_status=$?
set -eu
if [ "$nvm_status" -ne 0 ]; then
  echo "nvm could not install/select Node 20 (status $nvm_status)"
  exit 1
fi
case "$(node --version)" in
  v20.*) ;;
  *)
    echo "expected Node 20 after nvm use, got $(node --version)"
    exit 1
    ;;
esac
echo "driver node $(node --version), npm $(npm --version)"

# --- headless browser driver ---
# From the public registry with an empty user config: ~/.npmrc carries the
# time-machine registry/token/always-auth set in before_install for the
# node 0.10 build, which must not apply to the driver install.
mkdir -p "$DRIVER_DIR"
: > "$DRIVER_DIR/npmrc-public"
(
  cd "$DRIVER_DIR"
  export npm_config_userconfig="$DRIVER_DIR/npmrc-public"
  npm init -y > /dev/null
  npm install --no-audit --no-fund --registry=https://registry.npmjs.org/ puppeteer-core@22
)

CHROME_PATH="$(command -v google-chrome-stable || command -v google-chrome)"
echo "CHROME_PATH=$CHROME_PATH"
"$CHROME_PATH" --version

# Prefer the apt php-cli installed in before_install (PHP_CLI_SERVER_WORKERS
# needs PHP >= 7.4); fall back to whatever php is on PATH.
PHP_BIN=/usr/bin/php
if [ ! -x "$PHP_BIN" ]; then
  PHP_BIN="$(command -v php)"
fi
"$PHP_BIN" --version

# --- PHP server for the test/data/*.php ajax fixtures ---
# Multiple workers are load-bearing: single-process php -S starves the
# fixture iframes the suite opens.
PHP_CLI_SERVER_WORKERS=10 "$PHP_BIN" -S 127.0.0.1:8000 -t . > "$PHP_LOG" 2>&1 &
PHP_PID=$!
stop_php() {
  if kill -0 "$PHP_PID" 2> /dev/null; then
    kill "$PHP_PID"
  fi
}
trap stop_php EXIT

ready=0
for _ in $(seq 1 30); do
  if curl -sf "$SUITE_URL" > /dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "PHP server did not come up"
  cat "$PHP_LOG"
  exit 1
fi

# --- QUnit suite ---
status=0
NODE_PATH="$DRIVER_DIR/node_modules" CHROME_PATH="$CHROME_PATH" \
  node test/seal-browser-runner.js "$SUITE_URL" || status=$?
if [ "$status" -ne 0 ]; then
  echo "--- php log (tail) ---"
  tail -n 100 "$PHP_LOG"
fi
exit "$status"

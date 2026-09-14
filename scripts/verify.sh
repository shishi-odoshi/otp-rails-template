#!/usr/bin/env bash
# End-to-end proof the template works: generate a fresh app from template.rb,
# boot it under bin/supervise, and run every chaos task (recovery < 10s each).
# Used by CI and runnable locally (any Linux/macOS with ruby >= 3.2).
set -euxo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export RAILS_ENV=production SECRET_KEY_BASE=chaos-verify PORT="${PORT:-3000}"

gem list -i rails >/dev/null 2>&1 || gem install rails --no-document

WORK="$(mktemp -d)"
rails new "$WORK/demo" -m "$REPO/template.rb" --skip-git
cd "$WORK/demo"

bin/rails db:prepare

bin/supervise &
SUP=$!
cleanup() { kill -TERM "$SUP" 2>/dev/null || true; wait "$SUP" 2>/dev/null || true; }
trap cleanup EXIT

# wait for the tree to come up (web answers /up)
for _ in $(seq 90); do
  curl -fsS "http://127.0.0.1:$PORT/up" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/up" >/dev/null

bin/rails "chaos:kill[web]"
bin/rails "chaos:kill[jobs]"

# clean stop must exit 0 (odoshi contract)
kill -TERM "$SUP"
wait "$SUP"
trap - EXIT
echo "verify: all chaos tasks recovered and the supervisor stopped cleanly"

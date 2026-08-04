#!/usr/bin/env bash
# Spling connector test suite.
#
# The runtime is Deno (Supabase Edge Functions), but the pure modules are
# written to run anywhere, so the suite executes under Node's type-stripping
# with no install step and no network. Deno users can run the same files with
#   deno test --allow-none
#
# Usage: ./test.sh
set -euo pipefail

cd "$(dirname "$0")/supabase/functions/spling-mcp"

if ! command -v node >/dev/null 2>&1; then
  echo "node is required (v22+, for --experimental-strip-types)" >&2
  exit 1
fi

fail=0
for suite in compose_test.ts compose_domains_test.ts ledger_test.ts protocol_test.ts; do
  echo "── $suite"
  node --experimental-strip-types "$suite" || fail=1
done

if [ "$fail" -ne 0 ]; then
  echo "SUITE FAILED" >&2
  exit 1
fi
echo "All suites passed."

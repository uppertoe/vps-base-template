#!/usr/bin/env bash
# Shim: the canonical copy lives in the scaffold (scaffold/scripts/server/).
# Do not edit here; see scaffold/docs/14-server-tooling.md.
SERVER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SERVER_ROOT
exec bash "$SERVER_ROOT/scaffold/scripts/server/ci-forward-auth-test.sh" "$@"

#!/usr/bin/env bash
# Stops everything and discards all state, so the next ./up.sh starts clean.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
docker compose down -v
rm -rf .state warden.hcl
echo "Stopped. ./plugins and .env are kept; delete them too for a full reset."

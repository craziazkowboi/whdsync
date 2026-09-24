#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)
# Purpose: build or update the ECS variant (retro_ecs) - a thin wrapper around start.sh.
# Inputs:  any start.sh option, e.g. --rebuild, --clean, --skip-update
# Outputs: whatever start.sh --sync does for this one variant
# Safety:  no logic of its own; all safety rules live in all.sh/start.sh
# Called by: people, and by cron only through all.sh --cron
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/start.sh" --sync --ecs "$@"

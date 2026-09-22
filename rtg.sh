#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)
# Builds or updates the RTG variant (retro_rtg). Extra options are passed
# through to start.sh, for example:
#   ./rtg.sh --rebuild   rebuild from the downloaded archives, no update check
#   ./rtg.sh --clean     check for updates, then rebuild from scratch
#   ./all.sh --rtg --dry-run   preview what would happen
# Art order, detox and filesystem defaults come from retroplay.conf.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec ./start.sh --auto --rtg "$@"

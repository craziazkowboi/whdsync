#!/usr/bin/env bash
set -e
# cd to this script's own directory first, so it works no matter where
# it's run from (e.g. ~/retroplay/aga.sh from your home directory) -
# start.sh is called with a relative path below.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
./start.sh --auto --aga --no-detox "$@"

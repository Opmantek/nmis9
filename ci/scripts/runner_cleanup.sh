#!/usr/bin/env bash
set -euo pipefail

cd "$WORKING_DIRECTORY"

ids="$("/usr/bin/docker" ps -aq || true)"
if [[ -n "$ids" ]]; then
    sudo -n /usr/bin/docker rm -f $ids
fi

/usr/bin/docker volume prune -fa
sudo -n /usr/bin/chown -R $(whoami):$(whoami) "$WORKING_DIRECTORY"

if [[ -d "$WORKING_DIRECTORY/build" ]]; then
    sudo -n rm -rf "$WORKING_DIRECTORY/build"
fi

exit 0
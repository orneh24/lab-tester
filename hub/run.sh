#!/bin/sh
# Foreground launcher for the mesh-probe hub (manual runs and debugging).
# In production the OpenRC service mesh-probe-hub runs serve.py directly.

cd "$(dirname "$0")" || exit 1

# Pick up hub.env if present so a manual run matches the service's config.
if [ -f ./hub.env ]; then
    while IFS= read -r line; do
        case "$line" in
            \#*|"") continue ;;
            *=*) export "$line" ;;
        esac
    done < ./hub.env
fi

exec python3 ./serve.py

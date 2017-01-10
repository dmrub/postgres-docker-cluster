#!/usr/bin/env bash
set -e

# Supervisor bootstrap
echo ">>> Supervisor bootstrap"

# Load arguments
if [ -e "/etc/args.sh" ]; then
    source "/etc/args.sh"
fi

supervisorctl status

# Execute main entrypoint
exec /usr/local/bin/cluster/entrypoint.sh "$@"

#!/usr/bin/env bash
set -e

# Store passed arguments

SET_CMD="set -- "
for ARG in "$@"; do
    printf -v VAL "%q" "$ARG"
    SET_CMD="$SET_CMD $VAL"
done

echo "$SET_CMD" > /etc/args.sh

mkdir -p /var/run/supervisor || exit 1
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf

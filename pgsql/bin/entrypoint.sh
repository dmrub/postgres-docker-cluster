#!/usr/bin/env bash
set -e
#echo '>>> STARTING SSH SERVER...'
#/usr/local/bin/cluster/ssh/start.sh

echo '>>> STARTING POSTGRES...'
exec /usr/local/bin/cluster/postgres/entrypoint.sh

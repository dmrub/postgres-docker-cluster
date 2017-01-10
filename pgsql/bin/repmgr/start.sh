#!/usr/bin/env bash

echo ">>> Waiting postgres on this node to start repmgr..."
wait_db "$CLUSTER_NODE_NETWORK_NAME" "$REPLICATION_PRIMARY_PORT" "$REPLICATION_USER" "$REPLICATION_PASSWORD" "$REPLICATION_DB"

echo ">>> Registering node with role $CURRENT_NODE_TYPE"
if ! gosu postgres repmgr "$CURRENT_NODE_TYPE" register --force; then
    echo ">>>>>> Can't re-register node. Means it has been already done before!"

    sqlcmd() {
        echo ">>>> SQL command to $REPLICATION_DB database:"
        echo ">>>> $1"
        gosu postgres psql "$REPLICATION_DB" -c "$1"
    }

    echo ">>> Registering node with role $CURRENT_NODE_TYPE failed, trying to remove upstream_node_ids"
    sqlcmd "DELETE FROM repmgr_${CLUSTER_NAME}.repl_nodes WHERE upstream_node_id IN (SELECT id FROM repmgr_pg_cluster.repl_nodes WHERE type = '$CURRENT_NODE_TYPE');"
    sqlcmd "DELETE FROM repmgr_${CLUSTER_NAME}.repl_nodes WHERE type = '$CURRENT_NODE_TYPE';"
    echo ">>>> Registering node again with role $CURRENT_NODE_TYPE"
    gosu postgres repmgr "$CURRENT_NODE_TYPE" register --force
fi

echo ">>> Starting repmgr daemon..."
rm -rf /tmp/repmgrd.pid
exec gosu postgres repmgrd -vvv --pid-file=/tmp/repmgrd.pid

#!/usr/bin/env bash
set -e

echo ">>> Kubernetes initialization"

msg() {
    echo >&2 "$*"
}

fatal() {
    echo >&2 "Fatal error: $*"
    exit 1
}

if [ -e "/var/run/secrets/kubernetes.io/serviceaccount/token" ]; then
    TOKEN=$(< "/var/run/secrets/kubernetes.io/serviceaccount/token")

    kube-request() {
            curl --fail -sL --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
             -H "Authorization: Bearer $TOKEN" \
             "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}${1}"
    }

    kube-patch() {
        curl --fail -sL --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
            -X PATCH \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/strategic-merge-patch+json" \
            -d "$2" \
            "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}${1}"
    }

elif [ -n "$KUBERNETES_PROXY_HOST" -a -n "$KUBERNETES_PROXY_PORT" ]; then

    kube-request() {
        curl --fail -sL "http://${KUBERNETES_PROXY_HOST}:${KUBERNETES_PROXY_PORT}${1}"
    }

    kube-patch() {
        curl --fail -sL -X PATCH -H "Content-Type: application/strategic-merge-patch+json" \
            -d "$2" "http://${KUBERNETES_PROXY_HOST}:${KUBERNETES_PROXY_PORT}${1}"
    }
else
    echo >&2 "Error: No Kubernetes environment detected !"
    exit 1
fi

kube-get-host-for() {
    python -c '''import json,sys;
obj=json.load(sys.stdin)
items = obj["items"]
d = {}
for item in items:
    name = item.get("metadata", {}).get("name", None)
    if not name:
        continue
    addresses = item.get("status", {}).get("addresses", None)
    if not addresses:
        continue
    for addritem in addresses:
        address = addritem.get("address", None)
        if address:
            d[name] = address
            d[address] = name

for arg in sys.argv[1:]:
    r = d.get(arg)
    if r:
        print r
''' "$@"
}

kube-get-host-ip() {
    python -c 'import json,sys;obj=json.load(sys.stdin);print obj["status"]["hostIP"]' "$@"
}

kube-get-pod-ip() {
    python -c 'import json,sys;obj=json.load(sys.stdin);print obj["status"]["podIP"]' "$@"
}

kube-get-resourceVersion() {
    python -c 'import json,sys;obj=json.load(sys.stdin);print obj["metadata"]["resourceVersion"]' "$@"
}

kube-get-annotation() {
    python -c '''import json,sys;
obj=json.load(sys.stdin)
d = obj.get("metadata", {}).get("annotations", {})

for arg in sys.argv[1:]:
    r = d.get(arg)
    if r:
        print r
''' "$@"
}


# Set annotation value
# $1 object path
# $2 annotation name
# $3 new annotation value
kube-obj-set-annotation() {
    local objpath=$1
    local annoname=$2
    local val=$3

    kube-patch "$objpath" "{\"metadata\":{\"annotations\":{\"${annoname}\":\"${val}\"}}}"
}

# Increment annotation value atomically
# $1 object path
# $2 annotation name
# $3 increment value
# returns value before and after increment
kube-obj-incr-annotation() {
    local ret_old=false ret_new=true

    while [[ $# > 0 ]]; do
        case "$1" in
            --return-new)
                ret_new=true
                ret_old=false
                shift
                ;;
            --return-old)
                ret_old=true
                ret_new=false
                shift
                ;;
            --return-all)
                ret_old=true
                ret_new=true
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo >&2 "$0: error: unknown option $1"
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done

    local objpath=$1
    local annoname=$2
    local incrval=$3
    local resp resourceVersion val newval
    while true; do
        resp=$(kube-request "$objpath")
        resourceVersion=$(kube-get-resourceVersion <<<"$resp")
        val=$(kube-get-annotation "$annoname" <<<"$resp")
        let newval=val+incrval

        if resp=$(kube-patch "$objpath" "{\"metadata\":{\"resourceVersion\":\"${resourceVersion}\", \"annotations\":{\"${annoname}\":\"${newval}\"}}}"); then
            if $ret_old; then
                echo "$val"
            fi
            if $ret_new; then
                kube-get-annotation "$annoname" <<<"$resp"
            fi
            break
        else
            msg "[kube-obj-incr-annotation] Increment failed (val=$val, increment=$incrval, newval=$newval, resourceVersion=$resourceVersion)"
        fi
    done
}

if [ -z "$POD_NAME" -o -z "$POD_NAMESPACE" -o -z "$ENDPOINTS_NAME" ]; then
    fatal "POD_NAME='$POD_NAME' or POD_NAMESPACE='$POD_NAMESPACE' or ENDPOINTS_NAME='$ENDPOINTS_NAME' variables are not set or empty"
fi

POD_LINK="/api/v1/namespaces/${POD_NAMESPACE}/pods/${POD_NAME}"
POD_RESP=$(kube-request "$POD_LINK")
NODES_RESP=$(kube-request "/api/v1/nodes")
ENDPOINTS_LINK="/api/v1/namespaces/${POD_NAMESPACE}/endpoints/${ENDPOINTS_NAME}"
ENDPOINTS_RESP=$(kube-request "$ENDPOINTS_LINK")

HOST_IP=$(kube-get-host-ip <<<"$POD_RESP")
POD_IP=$(kube-get-pod-ip <<<"$POD_RESP")
HOST_NAME=$(kube-get-host-for "$HOST_IP" <<<"$NODES_RESP")

NODE_ID=$(kube-get-annotation "pgsql/node-id" <<<"$POD_RESP")
NODE_ID_ORIG=$NODE_ID

while [[ ! ( "$NODE_ID" =~ ^[0-9]+$ ) || "$NODE_ID" -le 0 ]]; do
   echo "NODE_ID='$NODE_ID' is not a number"

   NODE_ID=$(kube-obj-incr-annotation --return-new "${ENDPOINTS_LINK}" "pgsql/counter" 1)
done

if [ "$NODE_ID" != "$NODE_ID_ORIG" ]; then
    kube-obj-set-annotation "$POD_LINK" "pgsql/node-id" "$NODE_ID"
fi

echo "POD_NAME       = $POD_NAME"
echo "POD_NAMESPACE  = $POD_NAMESPACE"
echo "HOST_IP        = $HOST_IP"
echo "HOST_NAME      = $HOST_NAME"
echo "NODE_ID        = $NODE_ID"
echo "NODE_ID_ORIG   = $NODE_ID_ORIG"

if [ "$HOST_IP" = "$POD_IP" ]; then
    echo ">>> K8S: Host network mode detected !"
    HOST_NETWORK=1
else
    HOST_NETWORK=0
fi

out="$(/usr/local/bin/cluster/kubernetes/kube-init.py)"
if [[ $? == 0 ]]; then
    echo ">>> Kubernetes environment from kube-init.py:"
    echo "$out"
    export NODE_ID NODE_NAME
    eval "$out" || exit 1
    export CLUSTER_NODE_NETWORK_NAME=$(hostname)
    #export NODE_NAME=$CLUSTER_NODE_NETWORK_NAME

    if [[ "$HOST_NETWORK" == "1" ]]; then
        export NODE_NAME="$HOST_NAME"
    else
        export NODE_NAME="node${NODE_ID}"
    fi

    export CURRENT_NODE_TYPE="$NODE_TYPE"
    echo ">>> Set CLUSTER_NODE_NETWORK_NAME to $CLUSTER_NODE_NETWORK_NAME"
    echo ">>> Set NODE_NAME to $NODE_NAME"
    echo ">>> Set CURRENT_NODE_TYPE to $CURRENT_NODE_TYPE"
    if [ -n "$MASTER_NAME" -a -n "$MASTER_IP" ]; then

        MASTER_POD_RESP=$(kube-request "/api/v1/namespaces/${POD_NAMESPACE}/pods/${MASTER_NAME}")

        MASTER_HOST_IP=$(kube-get-host-ip <<<"$MASTER_POD_RESP")
        MASTER_HOST_NAME=$(kube-get-host-for "$MASTER_HOST_IP" <<<"$NODES_RESP")

        if [ "$MASTER_HOST_IP" = "$MASTER_IP" ]; then
            echo ">>> K8S: Host network mode for master detected !"
            MASTER_NAME=$MASTER_HOST_NAME
        fi

        echo ">>> Adding '$MASTER_IP $MASTER_NAME' entry to /etc/hosts"
        etchosts update "$MASTER_NAME" "$MASTER_IP"
    fi
    if [[ "$NODE_TYPE" == "master" ]]; then
        export CURRENT_REPLICATION_UPSTREAM_NODE_ID=""
        export CURRENT_REPLICATION_PRIMARY_HOST=""
    else
        export CURRENT_REPLICATION_UPSTREAM_NODE_ID="$MASTER_ID"
        export CURRENT_REPLICATION_PRIMARY_HOST="$MASTER_NAME"
    fi
    echo ">>> Set REPLICATION_UPSTREAM_NODE_ID to $REPLICATION_UPSTREAM_NODE_ID"
    echo ">>> Set CURRENT_REPLICATION_PRIMARY_HOST to $CURRENT_REPLICATION_PRIMARY_HOST"
else
    # Kubernetes initialization failed
    exit 1
fi

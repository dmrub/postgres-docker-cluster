#!/bin/bash

error() {
    echo >&2 "* Error: $@"
}

fatal() {
    error "$@"
    exit 1
}

message() {
    echo "$@"
}

THIS_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")

docker-build() {
    docker build -t "$1" -f "$2" \
           "$THIS_DIR" && \
        echo "Successfully built docker image $1"
}

docker-build "postgresql-cluster-pgsql" "$THIS_DIR/Pgsql.Dockerfile" || exit 1
docker-build "postgresql-cluster-pgpool" "$THIS_DIR/Pgpool.Dockerfile" || exit 1

#!/bin/sh
#
# Copyright 2019 PingCAP, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu
TEST_DIR=/tmp/lightning_test_result
SELECTED_TEST_NAME="${TEST_NAME-$(find tests -mindepth 2 -maxdepth 2 -name run.sh | cut -d/ -f2 | sort)}"
export PATH="tests/_utils:$PATH"

stop_services() {
    killall -9 tikv-server || true
    killall -9 pd-server || true
    killall -9 tidb-server || true
    killall -9 tikv-importer || true
    killall -9 tiflash || true

    find "$TEST_DIR" -maxdepth 1 -not -path "$TEST_DIR" -not -name "cov.*" -not -name "*.log" | xargs rm -r || true
}

start_services() {
    stop_services

    TT="$TEST_DIR/tls"
    mkdir -p "$TT"
    rm -f "$TEST_DIR"/*.log

    # Ref: https://docs.microsoft.com/en-us/azure/application-gateway/self-signed-certificates
    # gRPC only supports P-256 curves, see https://github.com/grpc/grpc/issues/6722
    echo "Generate TLS keys..."
    cat - > "$TT/ipsan.cnf" <<EOF
[dn]
CN = localhost
[req]
distinguished_name = dn
[EXT]
subjectAltName = @alt_names
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth,serverAuth
[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF
    openssl ecparam -out "$TT/ca.key" -name prime256v1 -genkey
    openssl req -new -batch -sha256 -subj '/CN=localhost' -key "$TT/ca.key" -out "$TT/ca.csr"
    openssl x509 -req -sha256 -days 2 -in "$TT/ca.csr" -signkey "$TT/ca.key" -out "$TT/ca.pem" 2> /dev/null
    for cluster in tidb pd tikv importer lightning tiflash curl; do
        openssl ecparam -out "$TT/$cluster.key" -name prime256v1 -genkey
        openssl req -new -batch -sha256 -subj '/CN=localhost' -key "$TT/$cluster.key" -out "$TT/$cluster.csr"
        openssl x509 -req -sha256 -days 1 -extensions EXT -extfile "$TT/ipsan.cnf" -in "$TT/$cluster.csr" -CA "$TT/ca.pem" -CAkey "$TT/ca.key" -CAcreateserial -out "$TT/$cluster.pem" 2> /dev/null
    done

    cat - > "$TEST_DIR/pd-config.toml" <<EOF
data-dir = "$TEST_DIR/pd"
client-urls = "https://127.0.0.1:2379"
peer-urls = "https://127.0.0.1:2380"

[log.file]
filename = "$TEST_DIR/pd.log"

[replication]
enable-placement-rules = true
max-replicas = 1

[schedule]
low-space-ratio = 0.99

[security]
cacert-path = "$TT/ca.pem"
cert-path = "$TT/pd.pem"
key-path = "$TT/pd.key"
EOF
    echo "Starting PD..."
    bin/pd-server --config "$TEST_DIR/pd-config.toml" &
    # wait until PD is online...
    i=0
    while ! run_curl https://127.0.0.1:2379/pd/api/v1/version; do
        i=$((i+1))
        if [ "$i" -gt 10 ]; then
            echo 'Failed to start PD'
            exit 1
        fi
        sleep 1
    done

    # Tries to limit the max number of open files under the system limit
    cat - > "$TEST_DIR/tikv-config.toml" <<EOF
log-file = "$TEST_DIR/tikv.log"
[server]
addr = "127.0.0.1:20160"
[storage]
data-dir = "$TEST_DIR/tikv"
[pd]
endpoints = ["https://127.0.0.1:2379"]
[rocksdb]
max-open-files = 4096
[raftdb]
max-open-files = 4096
[security]
ca-path = "$TT/ca.pem"
cert-path = "$TT/tikv.pem"
key-path = "$TT/tikv.key"
EOF
    echo "Starting TiKV..."
    bin/tikv-server -C "$TEST_DIR/tikv-config.toml" &
    sleep 1

    cat - > "$TEST_DIR/tidb-config.toml" <<EOF
host = "127.0.0.1"
port = 4000
store = "tikv"
path = "127.0.0.1:2379"
[status]
status-host = "127.0.0.1"
status-port = 10080
[log.file]
filename = "$TEST_DIR/tidb.log"
[security]
ssl-ca = "$TT/ca.pem"
ssl-cert = "$TT/tidb.pem"
ssl-key = "$TT/tidb.key"
cluster-ssl-ca = "$TT/ca.pem"
cluster-ssl-cert = "$TT/tidb.pem"
cluster-ssl-key = "$TT/tidb.key"
EOF
    echo "Starting TiDB..."
    bin/tidb-server --config "$TEST_DIR/tidb-config.toml" &

    cat - > "$TEST_DIR/importer-config.toml" <<EOF
log-file = "$TEST_DIR/importer.log"
[server]
addr = "127.0.0.1:8808"
[import]
import-dir = "$TEST_DIR/importer"
[security]
ca-path = "$TT/ca.pem"
cert-path = "$TT/importer.pem"
key-path = "$TT/importer.key"
EOF
    echo "Starting Importer..."
    bin/tikv-importer --config "$TEST_DIR/importer-config.toml" &

    echo "Verifying TiDB is started..."
    i=0
    export TEST_NAME=waiting_for_tidb
    while ! run_sql 'select * from mysql.tidb;'; do
        i=$((i+1))
        if [ "$i" -gt 10 ]; then
            echo 'Failed to start TiDB'
            exit 1
        fi
        sleep 3
    done

    cat > $TEST_DIR/tiflash-learner.toml <<eof
[rocksdb]
wal-dir = ""

[security]
ca-path = "$TT/ca.pem"
cert-path = "$TT/tiflash.pem"
key-path = "$TT/tiflash.key"

[server]
addr = "0.0.0.0:20170"
advertise-addr = "127.0.0.1:20170"
engine-addr = "127.0.0.1:3930"
status-addr = "127.0.0.1:17000"

[storage]
data-dir = "$TEST_DIR/tiflash/data"
eof

    cat - > "$TEST_DIR/tiflash.toml" <<EOF
default_profile = "default"
display_name = "TiFlash"
https_port = 8125
listen_host = "0.0.0.0"
mark_cache_size = 5368709120
path = "$TEST_DIR/tiflash/data"
tcp_port_secure = 9002
tmp_path = "/tmp/tiflash"
capacity = "10737418240"

[application]
runAsDaemon = true

[flash]
service_addr = "127.0.0.1:3930"
tidb_status_addr = "127.0.0.1:10080"

[flash.proxy]
config = "$TEST_DIR/tiflash-learner.toml"
log-file = "$TEST_DIR/tiflash-proxy.log"

[flash.flash_cluster]
cluster_manager_path = "$PWD/bin/flash_cluster_manager"
log = "$TEST_DIR/tiflash-manager.log"
master_ttl = 60
refresh_interval = 20
update_rule_interval = 5

[logger]
count = 20
level = "trace"
log = "$TEST_DIR/tiflash-stdout.log"
errorlog = "$TEST_DIR/tiflash-stderr.log"
size = "1000M"

[raft]
pd_addr = "127.0.0.1:2379"

[profiles]
[profiles.default]
load_balancing = "random"
max_memory_usage = 10000000000
use_uncompressed_cache = 0

[users]
[users.default]
password = ""
profile = "default"
quota = "default"
[users.default.networks]
ip = "::/0"
[users.readonly]
password = ""
profile = "readonly"
quota = "default"
[users.readonly.networks]
ip = "::/0"

[quotas]
[quotas.default]
[quotas.default.interval]
duration = 3600
errors = 0
execution_time = 0
queries = 0
read_rows = 0
result_rows = 0

[security]
ca_path = "$TT/ca.pem"
cert_path = "$TT/tiflash.pem"
key_path = "$TT/tiflash.key"
EOF
    rm -rf $TEST_DIR/tiflash /tmp/tiflash
    echo "Starting TiFlash..."
    LD_LIBRARY_PATH=bin/ bin/tiflash server --config-file="$TEST_DIR/tiflash.toml" &
    echo "TiFlash started..."

    i=0
    while ! run_curl https://127.0.0.1:8125 1>/dev/null 2>&1; do
        i=$((i+1))
        if [ "$i" -gt 60 ]; then
            echo "failed to start tiflash"
            return 1
        fi
        echo "TiFlash seems doesn't started, retrying..."
        sleep 3
    done
}

trap stop_services EXIT
start_services

# Intermediate file needed because `read` can be used as a pipe target.
# https://stackoverflow.com/q/2746553/
run_curl 'https://127.0.0.1:2379/pd/api/v1/version' | grep -o 'v[0-9.]\+' > "$TEST_DIR/cluster_version.txt"
IFS='.' read CLUSTER_VERSION_MAJOR CLUSTER_VERSION_MINOR CLUSTER_VERSION_REVISION < "$TEST_DIR/cluster_version.txt"

if [ "${1-}" = '--debug' ]; then
    echo 'You may now debug from another terminal. Press [ENTER] to continue.'
    read line
fi

echo "selected test cases: $SELECTED_TEST_NAME"

# disable cluster index by default
run_sql 'set @@global.tidb_enable_clustered_index = 0' || echo "tidb does not support cluster index yet, skipped!"
# wait for global variable cache invalid
sleep 2

for casename in $SELECTED_TEST_NAME; do
    script=tests/$casename/run.sh
    echo "\x1b[32;1m@@@@@@@ Running test $script...\x1b[0m"
    TEST_DIR="$TEST_DIR" \
    TEST_NAME="$casename" \
    CLUSTER_VERSION_MAJOR="${CLUSTER_VERSION_MAJOR#v}" \
    CLUSTER_VERSION_MINOR="$CLUSTER_VERSION_MINOR" \
    CLUSTER_VERSION_REVISION="$CLUSTER_VERSION_REVISION" \
    sh "$script"
done

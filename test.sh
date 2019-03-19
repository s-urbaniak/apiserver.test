#!/bin/bash

set -exuo pipefail

export KUBECONFIG=_output/tls/kubeconfig

if [[ ! -f _output/etcd/etcd ]]; then
    v=3.2.24
    url="https://github.com/etcd-io/etcd/releases/download/v${v}/etcd-v${v}-linux-amd64.tar.gz"
    mkdir -p _output/etcd
    curl -# -w '' -L "${url}" | tar --strip-components=1 -xzf - -C _output/etcd
fi
export PATH=$PATH:$(pwd)/_output/etcd

if [[ ! -f _output/prometheus/prometheus ]]; then
    v=2.3.2
    url="https://github.com/prometheus/prometheus/releases/download/v${v}/prometheus-${v}.$(go env GOOS)-$(go env GOARCH).tar.gz"
    echo "Downloading prometheus from ${url}"
    mkdir -p _output/prometheus
    curl -# -w '' -L "${url}" | tar --strip-components=1 -xzf - -C _output/prometheus
fi
export PATH=$PATH:$(pwd)/_output/prometheus

if [[ ! -d _output/kube ]]; then
    v=1.13.3
    url="https://dl.k8s.io/v${v}/kubernetes-server-linux-amd64.tar.gz"
    mkdir -p _output/kube
    curl -# -w '' -L "${url}" | tar --strip-components=1 -xzf - -C _output/kube
fi
export PATH=$PATH:$(pwd)/_output/kube

if [[ ! -d _output/tls ]]; then
    tls_dir=_output/tls
    mkdir -p "${tls_dir}"

    # ca
    openssl genrsa -out "${tls_dir}/ca.key" 2048
    openssl req -x509 -new -nodes \
            -key "${tls_dir}/ca.key" \
            -days 10000 \
            -out "${tls_dir}/ca.crt" \
            -subj "/CN=kube-ca"

    # apiserver
    openssl genrsa -out "${tls_dir}/apiserver.key" 2048
    openssl req -new \
            -key "${tls_dir}/apiserver.key" \
            -out "${tls_dir}/apiserver.csr" \
            -subj "/CN=kube-api" \
            -config openssl-api.cnf

    openssl x509 -req \
            -in "${tls_dir}/apiserver.csr" \
            -CA "${tls_dir}/ca.crt" \
            -CAkey "${tls_dir}/ca.key" \
            -CAcreateserial -out "${tls_dir}/apiserver.crt" \
            -days 365 -extensions v3_req -extfile openssl-api.cnf

    # aggregator
    openssl genrsa -out "${tls_dir}/agg-ca.key" 2048
    openssl req -x509 -new -nodes \
            -key "${tls_dir}/agg-ca.key" \
            -days 10000 \
            -out "${tls_dir}/agg-ca.crt" \
            -subj "/CN=kube-aggregator-ca"

    openssl genrsa -out "${tls_dir}/proxy-client.key" 2048

    openssl req -new \
            -key "${tls_dir}/proxy-client.key" \
            -out "${tls_dir}/proxy-client.csr" \
            -subj "/CN=proxy-client" \
            -config openssl-agg.cnf

    openssl x509 -req \
            -in "${tls_dir}/proxy-client.csr" \
            -CA "${tls_dir}/agg-ca.crt" \
            -CAkey "${tls_dir}/agg-ca.key" \
            -CAcreateserial -out "${tls_dir}/proxy-client.crt" \
            -days 365 -extensions v3_req -extfile openssl-agg.cnf

    # client
    openssl genrsa -out "${tls_dir}/client.key" 2048
    openssl req -new \
            -key "${tls_dir}/client.key" \
            -out "${tls_dir}/client.csr" \
            -subj "/CN=client/O=system:masters" \
            -config openssl-client.cnf

    openssl x509 -req \
            -in "${tls_dir}/client.csr" \
            -CA "${tls_dir}/ca.crt" \
            -CAkey "${tls_dir}/ca.key" \
            -CAcreateserial -out "${tls_dir}/client.crt" \
            -days 365 -extensions v3_req \
            -extfile openssl-client.cnf

    # serviceaccount
    openssl genrsa \
            -out "${tls_dir}/service-account.key" \
            2048

    openssl rsa \
            -in "${tls_dir}/service-account.key" \
            -pubout >"${tls_dir}/service-account.pub"

    cat >"${tls_dir}/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: $(base64 -w 0 ${tls_dir}/ca.crt)
users:
- name: kubelet
  user:
    client-certificate-data: $(base64 -w 0 ${tls_dir}/client.crt)
    client-key-data: $(base64 -w 0 ${tls_dir}/client.key)
contexts:
- context:
    cluster: local
    user: kubelet
EOF
fi

ETCD_TEMP_DIR="$(mktemp -d)"

(
    etcd --name master0 \
         --data-dir "${ETCD_TEMP_DIR}" \
         \
         --advertise-client-urls "http://127.0.0.1:2379" \
         --listen-client-urls "http://127.0.0.1:2379" \
         \
         --heartbeat-interval 200 \
         --election-timeout 5000
) &

TSDB_TEMP_DIR="$(mktemp -d)"
(
    prometheus \
      --config.file=./prom-local.conf \
      --web.listen-address=localhost:9005 \
      "--storage.tsdb.path=${TSDB_TEMP_DIR}" \
      --log.level=warn \
) &

(
    go run main.go
) &

curl --retry 100 --retry-delay 1 --retry-connrefused -v http://127.0.0.1:2379/version

(
    ip=127.0.0.1
    tls_dir=_output/tls

    hyperkube apiserver \
    --secure-port=6443 \
    \
    --etcd-servers=http://127.0.0.1:2379 \
    --storage-backend=etcd3 \
    \
    --tls-cert-file=${tls_dir}/apiserver.crt \
    --tls-private-key-file=${tls_dir}/apiserver.key \
    --service-account-key-file=${tls_dir}/service-account.pub \
    \
    --client-ca-file=${tls_dir}/ca.crt \
    \
    --authorization-mode=RBAC \
    --anonymous-auth=false \
    --allow-privileged=true \
    --enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \
    \
    --service-cluster-ip-range=10.3.0.0/16 \
    \
    --feature-gates=PersistentLocalVolumes=true \
    \
    --requestheader-client-ca-file=${tls_dir}/agg-ca.crt \
    --proxy-client-cert-file=${tls_dir}/proxy-client.crt \
    --proxy-client-key-file=${tls_dir}/proxy-client.key \
    --requestheader-allowed-names=proxy-client \
    --requestheader-extra-headers-prefix=X-Remote-Extra- \
    --requestheader-group-headers=X-Remote-Group \
    --requestheader-username-headers=X-Remote-User
) &

KUBECTL=_output/kube/server/bin/kubectl
set +e
until $KUBECTL -n kube-system get configmap extension-apiserver-authentication; do
    sleep 1
done
set -e

export PATH=$PATH:$HOME/src/redhat/go/src/github.com/directxman12/k8s-prometheus-adapter/_output/amd64

(
    adapter \
        --prometheus-url=http://localhost:9005/ \
        --config=adapter.yaml \
        --secure-port=6445 \
        --authentication-kubeconfig=$KUBECONFIG \
        --authorization-kubeconfig=$KUBECONFIG \
        --lister-kubeconfig=$KUBECONFIG
) &

for i in `jobs -p`; do wait $i; done

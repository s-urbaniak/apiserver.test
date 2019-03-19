#!/bin/bash

set -euxo pipefail

if [[ ! -f _output/prometheus/prometheus ]]; then
  v=2.3.2
  url="https://github.com/prometheus/prometheus/releases/download/v${v}/prometheus-${v}.$(go env GOOS)-$(go env GOARCH).tar.gz"
  echo "Downloading prometheus from ${url}"
  mkdir -p _output/prometheus
  curl -w '' -L "${url}" 2>/dev/null | tar --strip-components=1 -xzf - -C _output/prometheus
fi
export PATH=$PATH:$(pwd)/_output/prometheus

(
    prometheus \
      --config.file=./prom-local.conf \
      --web.listen-address=localhost:9005 \
      "--storage.tsdb.path=$(mktemp -d)" \
      --log.level=warn \
) &

for i in `jobs -p`; do echo "waiting for job ${i}"; wait $i; done

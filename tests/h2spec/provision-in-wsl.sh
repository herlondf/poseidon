#!/usr/bin/env bash
# Provisions the throwaway distro with what the h2spec run needs:
# openssl (TLS cert + s_client), python3 (fetch the prebuilt h2spec), h2spec.
# Idempotent — safe to re-run.
set -e
export DEBIAN_FRONTEND=noninteractive

if ! getent hosts github.com >/dev/null; then
  echo "PROVISION_FAIL: no DNS/network in distro"; exit 1
fi

apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq openssl ca-certificates python3 >/dev/null 2>&1

if [ ! -x /usr/local/bin/h2spec ]; then
  # h2spec's tagged Go modules are broken for `go install` and master needs a
  # newer toolchain — use the official prebuilt release binary. python3 urllib
  # (not curl/wget) keeps this portable and quiet.
  python3 - <<'PY'
import urllib.request
url="https://github.com/summerwind/h2spec/releases/download/v2.6.0/h2spec_linux_amd64.tar.gz"
urllib.request.urlretrieve(url, "/tmp/h2spec.tar.gz")
PY
  tar -C /tmp -xzf /tmp/h2spec.tar.gz
  install -m755 /tmp/h2spec /usr/local/bin/h2spec
fi

echo "PROVISION_OK openssl=$(openssl version | awk '{print $2}') h2spec=$(h2spec --version 2>&1 | awk '{print $2}')"

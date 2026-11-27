#!/bin/bash
set -euo pipefail
PRISM_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PRISM_REGISTRY=${PRISM_TEST_REGISTRY:-docker.io/library}
PRISM_CA_FILE=${PRISM_TEST_CA_FILE:-}
if [ -z "$PRISM_CA_FILE" ]; then
    for PRISM_CA_CANDIDATE in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
        if [ -f "$PRISM_CA_CANDIDATE" ]; then
            PRISM_CA_FILE=$PRISM_CA_CANDIDATE
            break
        fi
    done
fi
set --
if [ -n "$PRISM_CA_FILE" ]; then
    test -f "$PRISM_CA_FILE"
    set -- -v "$PRISM_CA_FILE:/tmp/prism-test-ca.crt:ro"
fi
mkdir -p "$PRISM_REPO/build-linux/verification"
for PRISM_UBUNTU in 20.04 22.04 24.04; do
    docker run --rm --platform linux/amd64 \
        -v "$PRISM_REPO:/repo:ro" \
        -v "$PRISM_REPO/build-linux/verification:/verification" \
        -e PRISM_TEST_APT_MIRROR="${PRISM_TEST_APT_MIRROR:-}" \
        "$@" \
        "$PRISM_REGISTRY/ubuntu:$PRISM_UBUNTU" \
        bash /repo/linux/tests/in_container.sh \
        2>&1 | tee "$PRISM_REPO/build-linux/verification/ubuntu-$PRISM_UBUNTU.log"
done

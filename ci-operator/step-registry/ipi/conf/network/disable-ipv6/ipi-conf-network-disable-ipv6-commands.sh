#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/manifest_network-disable-ipv6-mc.yml" << EOF
kind: MachineConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: network-disable-ipv6
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: "${IGNITIONVERSION}"
    storage:
      files:
      - contents:
          # net.ipv6.conf.all.disable_ipv6=1
          source: data:text/plain;charset=utf-8;base64,bmV0LmlwdjYuY29uZi5hbGwuZGlzYWJsZV9pcHY2PTEK
        filesystem: root
        mode: 0644
        overwrite: true
        path: /etc/sysctl.d/90-disable-ipv6.conf
EOF

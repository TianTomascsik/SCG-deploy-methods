#!/bin/bash
# Entrypoint for the SCG gateway in shared-network mode.
# The gateway reads its intercept configuration and installs/tears down
# iptables rules automatically (ingress_redirect: port 8080 → 8443).
# No manual iptables setup is needed.

exec gateway --config-dir /etc/scg/config --log-stdout

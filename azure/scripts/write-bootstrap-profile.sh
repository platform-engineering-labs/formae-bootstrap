#!/usr/bin/env bash
#
# © 2025 Platform Engineering Labs Inc.
# SPDX-License-Identifier: FSL-1.1-ALv2
#
# Write a formae CLI profile that connects to an agent stood up by azure/bootstrap.pkl.
# Run this AFTER `formae apply` succeeds.
#
# public mode serves HTTPS with a SELF-SIGNED certificate, so the profile sets
# cli.api.insecureSkipVerify = true (needs a formae CLI with PR #540). tailnet
# mode serves a trusted *.ts.net certificate; connect via the tailnet FQDN.
# Both use the agent's listener port, 49684 (override with --port).
#
# auth-basic ships in the standard plugin bundle installed with the formae CLI, so the
# CLI can already send credentials - no extra plugin install is needed.
#
# Usage:
#   azure/scripts/write-bootstrap-profile.sh --profile NAME --password PASS \
#     --fqdn FQDN [--access public|tailnet] [--user formae] [--port 49684]

set -euo pipefail

profile="" password="" user="formae" fqdn="" port="49684" access="public"

usage() {
    sed -n '18,20p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)  profile="$2"; shift 2 ;;
        --password) password="$2"; shift 2 ;;
        --user)     user="$2"; shift 2 ;;
        --fqdn)     fqdn="$2"; shift 2 ;;
        --port)     port="$2"; shift 2 ;;
        --access)   access="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$profile" ] && [ -n "$password" ] || usage
[ -n "$fqdn" ] || { echo "error: --fqdn is required (e.g. formae-bootstrap.eastus.cloudapp.azure.com)" >&2; exit 1; }
case "$access" in public|appgw|tailnet) ;; *) echo "error: --access must be public, appgw or tailnet" >&2; exit 1 ;; esac

skipverify=""
if [ "$access" = "public" ]; then
    # Self-signed certificate: opt in to skipping verification (formae PR #540).
    skipverify=$'\n        insecureSkipVerify = true'
elif [ "$access" = "appgw" ]; then
    # The Application Gateway listens on :443. Its cert is self-signed by default
    # (skip verification); if you imported a trusted PFX (--cert-pfx), delete the
    # insecureSkipVerify line below.
    [ "$port" = "49684" ] && port="443"
    skipverify=$'\n        insecureSkipVerify = true'
fi

dir="${HOME}/.config/formae/profiles"
mkdir -p "$dir"
file="${dir}/${profile}.pkl"

cat > "$file" <<EOF
amends "formae:/Config.pkl"

import "plugins:/AuthBasic.pkl" as AuthBasic

// Connects to the formae agent stood up by azure/bootstrap.pkl (${access} mode).
cli {
    api {
        url = "https://${fqdn}"
        port = ${port}${skipverify}
    }
    auth = new AuthBasic.CliConfig {
        username = "${user}"
        password = "${password}"
    }
}
EOF

echo "wrote ${file}"
echo
echo "Use it for a single command (leaves your active profile unchanged):"
echo "  formae status agent --profile ${profile}"
echo "Or make it your default profile (all later commands target this agent):"
echo "  formae profile use ${profile}"

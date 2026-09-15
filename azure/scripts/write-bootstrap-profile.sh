#!/usr/bin/env bash
#
# © 2025 Platform Engineering Labs Inc.
# SPDX-License-Identifier: FSL-1.1-ALv2
#
# Write a formae CLI profile that connects to an agent stood up by azure/bootstrap.pkl.
# Run this AFTER `formae apply` succeeds.
#
# Every mode serves a certificate the CLI can verify: public and appgw use the
# certificate you supplied at apply time (--fqdn is your --domain), tailnet
# serves a trusted *.ts.net certificate (--fqdn is the tailnet FQDN). The CLI
# has no TLS-skip knob, so there is nothing to opt out of here.
# public and tailnet use the agent's listener port, 49684; appgw listens on 443
# (the default flips automatically). Override with --port.
#
# auth-basic ships in the standard plugin bundle installed with the formae CLI, so the
# CLI can already send credentials - no extra plugin install is needed.
#
# Usage:
#   azure/scripts/write-bootstrap-profile.sh --profile NAME --password PASS \
#     --fqdn FQDN [--access public|appgw|tailnet] [--user formae] [--port 49684]

set -euo pipefail

profile="" password="" user="formae" fqdn="" port="49684" access="public"

usage() {
    sed -n '19,21p' "$0" | sed 's/^# \{0,1\}//' >&2
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

# The Application Gateway listens on :443, not the agent's listener port.
if [ "$access" = "appgw" ] && [ "$port" = "49684" ]; then
    port="443"
fi

dir="${HOME}/.config/formae/profiles"
mkdir -p "$dir"
file="${dir}/${profile}.pkl"

cat > "$file" <<EOF
amends "formae:/Config.pkl"

import "formae:/Config.pkl" as Config
import "plugins:/AuthBasic.pkl" as AuthBasic

// Connects to the formae agent stood up by azure/bootstrap.pkl (${access} mode).
cli {
    connection = new Config.Classic {
        url = "https://${fqdn}"
        port = ${port}
        auth = new AuthBasic.CliConfig {
            username = "${user}"
            password = "${password}"
        }
    }
}
EOF

echo "wrote ${file}"
echo
echo "Use it for a single command (leaves your active profile unchanged):"
echo "  formae agent status --profile ${profile}"
echo "Or make it your default profile (all later commands target this agent):"
echo "  formae profile use ${profile}"

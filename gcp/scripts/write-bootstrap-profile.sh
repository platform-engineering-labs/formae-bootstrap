#!/usr/bin/env bash
#
# © 2025 Platform Engineering Labs Inc.
# SPDX-License-Identifier: FSL-1.1-ALv2
#
# Write a formae CLI profile that connects to an agent stood up by gcp/bootstrap.pkl.
# Run this AFTER `formae apply` succeeds. Tailnet mode serves the API over a trusted
# *.ts.net HTTPS certificate with basic auth; connect via the tailnet FQDN (the port
# is the agent's tsnet listener, 49684, override with --port).
#
# auth-basic ships in the standard plugin bundle installed with the formae CLI, so the
# CLI can already send credentials - no extra plugin install is needed.
#
# Usage:
#   gcp/scripts/write-bootstrap-profile.sh --profile NAME --password PASS \
#     --fqdn HOST.TAILNET.ts.net [--user formae] [--port 49684]

set -euo pipefail

profile="" password="" user="formae" fqdn="" port="49684"

usage() {
    sed -n '16,18p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)  profile="$2"; shift 2 ;;
        --password) password="$2"; shift 2 ;;
        --user)     user="$2"; shift 2 ;;
        --fqdn)     fqdn="$2"; shift 2 ;;
        --port)     port="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$profile" ] && [ -n "$password" ] || usage
[ -n "$fqdn" ] || { echo "error: --fqdn is required (e.g. formae-bootstrap.<tailnet>.ts.net)" >&2; exit 1; }

dir="${HOME}/.config/formae/profiles"
mkdir -p "$dir"
file="${dir}/${profile}.pkl"

cat > "$file" <<EOF
amends "formae:/Config.pkl"

import "plugins:/AuthBasic.pkl" as AuthBasic

// Connects to the formae agent stood up by gcp/bootstrap.pkl (tailnet mode):
// trusted *.ts.net HTTPS + basic auth, reached over your Tailscale tailnet.
cli {
    api {
        url = "https://${fqdn}"
        port = ${port}
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

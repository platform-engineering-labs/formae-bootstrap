#!/usr/bin/env bash
#
# © 2025 Platform Engineering Labs Inc.
# SPDX-License-Identifier: FSL-1.1-ALv2
#
# Write a formae CLI profile that connects to an agent stood up by aws/bootstrap.pkl.
# Run this AFTER `formae apply` succeeds. Both access modes serve the API over trusted HTTPS
# with basic auth, and you connect via the certificate's hostname (NOT the raw ALB DNS name
# — the cert won't match it). The port differs by mode (override with --port):
#   alb      --access alb     --domain <your-domain>          port 443 (the ALB HTTPS listener)
#   tailnet  --access tailnet --fqdn <host.<tailnet>.ts.net>  port 49684 (the agent's tsnet listener; no ALB)
#
# auth-basic ships in the standard plugin bundle installed with the formae CLI, so the CLI
# can already send credentials — no extra plugin install is needed.
#
# Usage:
#   aws/scripts/write-bootstrap-profile.sh --profile NAME --password PASS --domain DOMAIN [--user formae]
#   aws/scripts/write-bootstrap-profile.sh --profile NAME --password PASS --access tailnet --fqdn HOST.TAILNET.ts.net [--user formae]

set -euo pipefail

profile="" password="" user="formae" access="alb" domain="" fqdn="" port="443"

usage() {
    sed -n '19,21p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)  profile="$2"; shift 2 ;;
        --password) password="$2"; shift 2 ;;
        --user)     user="$2"; shift 2 ;;
        --access)   access="$2"; shift 2 ;;
        --domain)   domain="$2"; shift 2 ;;
        --fqdn)     fqdn="$2"; shift 2 ;;
        --port)     port="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$profile" ] && [ -n "$password" ] || usage

case "$access" in
    alb)
        host="$domain"
        [ -n "$host" ] || { echo "error: --domain is required for --access alb (the ACM cert's domain)" >&2; exit 1; } ;;
    tailnet)
        host="$fqdn"
        [ -n "$host" ] || { echo "error: --fqdn is required for --access tailnet (e.g. formae-bootstrap.<tailnet>.ts.net)" >&2; exit 1; } ;;
    *)
        echo "error: --access must be 'alb' or 'tailnet'" >&2; exit 1 ;;
esac

dir="${HOME}/.config/formae/profiles"
mkdir -p "$dir"
file="${dir}/${profile}.pkl"

cat > "$file" <<EOF
amends "formae:/Config.pkl"

import "plugins:/AuthBasic.pkl" as AuthBasic

// Connects to the formae agent stood up by aws/bootstrap.pkl (--access ${access}):
// trusted HTTPS on 443 + basic auth.
cli {
    api {
        url = "https://${host}"
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

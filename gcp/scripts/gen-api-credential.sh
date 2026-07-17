#!/usr/bin/env bash
#
# © 2025 Platform Engineering Labs Inc.
# SPDX-License-Identifier: FSL-1.1-ALv2
#
# Generate the formae agent API basic-auth credential for gcp/bootstrap.pkl.
#
# auth-basic validates incoming requests against a *bcrypt hash*, and nothing in
# the agent image or the formae CLI can produce one - so it is generated here, on
# your machine. Pass the printed hash to `formae apply --api-password-hash …`; it
# is stored in a Secret Manager SecretVersion and fetched by the VM at boot (never
# placed in instance metadata). Keep the printed password for
# scripts/write-bootstrap-profile.sh (your CLI profile).
#
# Usage: gcp/scripts/gen-api-credential.sh [username]   (username defaults to "formae")

set -euo pipefail

user="${1:-formae}"

if ! command -v openssl >/dev/null 2>&1; then
    echo "error: openssl is required to generate the password." >&2
    exit 1
fi

password="$(openssl rand -hex 16)"

# bcrypt hash via htpasswd; fall back to a one-shot httpd container if htpasswd is absent.
if command -v htpasswd >/dev/null 2>&1; then
    hash="$(htpasswd -nbBC 10 "" "$password" | cut -d: -f2)"
elif command -v docker >/dev/null 2>&1; then
    hash="$(docker run --rm httpd:2.4-alpine htpasswd -nbBC 10 "" "$password" | cut -d: -f2)"
else
    echo "error: need 'htpasswd' (apache2-utils / httpd-tools / brew httpd) or 'docker' to bcrypt-hash the password." >&2
    exit 1
fi

cat <<EOF
formae agent API credential
  username : ${user}
  password : ${password}

1. Apply the agent (tailnet mode) with this credential + your Tailscale auth key.
   The hash and the auth key are stored in Secret Manager and fetched by the VM
   at boot, never written into instance metadata:

   formae apply --mode reconcile gcp/bootstrap.pkl \\
     --project <gcp-project> \\
     --api-user ${user} --api-password-hash '${hash}' \\
     --ts-authkey <tskey> --ts-hostname formae-bootstrap \\
     --watch --status-output-layout detailed

2. After it is up, write a connected CLI profile (keep the password above):

   gcp/scripts/write-bootstrap-profile.sh --profile bootstrap \\
     --user ${user} --password '${password}' \\
     --fqdn formae-bootstrap.<your-tailnet>.ts.net
EOF

#!/usr/bin/env bash
#
# © 2025 Platform Engineering Labs Inc.
# SPDX-License-Identifier: FSL-1.1-ALv2
#
# Generate the formae agent API basic-auth credential for azure/bootstrap.pkl.
#
# auth-basic validates incoming requests against a *bcrypt hash*, and nothing in
# the agent image or the formae CLI can produce one - so it is generated here, on
# your machine. Pass the printed hash to `formae apply --api-password-hash …`.
# Keep the printed password for scripts/write-bootstrap-profile.sh (your CLI
# profile). The printed db-password is a stable Postgres admin password - pass
# it as --db-password and reuse the SAME value on every re-apply.
#
# Usage: azure/scripts/gen-api-credential.sh [username]   (username defaults to "formae")

set -euo pipefail

user="${1:-formae}"

if ! command -v openssl >/dev/null 2>&1; then
    echo "error: openssl is required to generate the password." >&2
    exit 1
fi

password="$(openssl rand -hex 16)"
dbpassword="$(openssl rand -hex 16)"

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
  username    : ${user}
  password    : ${password}
  db-password : ${dbpassword}

1. Apply the agent (public mode shown; see README for tailnet):

   formae apply --mode reconcile azure/bootstrap.pkl \\
     --subscription-id <sub-id> --tenant-id <tenant-id> \\
     --client-id <sp-appId> --client-secret '<sp-password>' \\
     --api-user ${user} --api-password-hash '${hash}' \\
     --db-password '${dbpassword}' \\
     --ssh-public-key "\$(cat ~/.ssh/id_ed25519.pub)" \\
     --watch --status-output-layout detailed

2. After it is up, write a connected CLI profile (keep the password above):

   azure/scripts/write-bootstrap-profile.sh --profile bootstrap --access public \\
     --user ${user} --password '${password}' \\
     --fqdn <name>.<location>.cloudapp.azure.com
EOF

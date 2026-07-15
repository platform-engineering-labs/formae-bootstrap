# Formae agent on Azure

One command stands up a production **formae agent** on Azure — a resource group, a VM running
the agent container, and an Azure Database for PostgreSQL Flexible Server (private endpoint,
no public DB access) — secure by default, in one of two access modes:

- **`public`** — the agent terminates HTTPS itself with a **self-signed certificate** generated
  on the VM at first boot, reachable at a stable `<name>.<location>.cloudapp.azure.com` FQDN,
  plus HTTP basic auth. Inbound restricted to `--allowed-cidr`.
- **`tailnet`** — private, reached only over your Tailscale tailnet (no public ingress), serving
  a trusted `*.ts.net` certificate, with basic auth on top.

Formae runs as a client and an agent: you use your local install to provision the agent's
permanent home in the cloud, then point your CLI at it with a profile and hand off.

## Prerequisites

- A **service principal** the agent operates Azure with:

  ```bash
  az ad sp create-for-rbac --name formae-agent --role Contributor \
    --scopes /subscriptions/<subscription-id>
  # note appId (--client-id), password (--client-secret), tenant (--tenant-id)
  ```

- An **SSH public key** (Azure requires one on the VM even if you never log in):
  `ssh-keygen -t ed25519` if you don't have one.
- `public` mode: a formae CLI with `cli.api.insecureSkipVerify`
  ([formae PR #540](https://github.com/platform-engineering-labs/formae/pull/540)) to accept
  the self-signed certificate.
- `tailnet` mode: a reusable Tailscale auth key tagged `tag:formae`, HTTPS certificates
  enabled in the tailnet admin console.

## Quickstart

```bash
git clone https://github.com/platform-engineering-labs/formae-bootstrap.git
cd formae-bootstrap

# Generate the basic-auth credential + a stable db password — keep the printed
# password; the hash and db-password go to the apply.
azure/scripts/gen-api-credential.sh
```

**`public`**:

```bash
formae apply --mode reconcile azure/bootstrap.pkl --access public --location <location> \
  --subscription-id <sub-id> --tenant-id <tenant-id> \
  --client-id <sp-appId> --client-secret '<sp-password>' \
  --api-user formae --api-password-hash '<hash>' --db-password '<dbpass>' \
  --ssh-public-key "$(cat ~/.ssh/id_ed25519.pub)" --watch

# Verify + connect (self-signed cert: -k / insecureSkipVerify):
curl -k https://formae-bootstrap.<location>.cloudapp.azure.com:49684/api/v1/health
azure/scripts/write-bootstrap-profile.sh --profile bootstrap --access public \
  --fqdn formae-bootstrap.<location>.cloudapp.azure.com --user formae --password '<password>'
formae status agent --profile bootstrap
```

**`tailnet`**:

```bash
formae apply --mode reconcile azure/bootstrap.pkl --access tailnet --location <location> \
  --subscription-id <sub-id> --tenant-id <tenant-id> \
  --client-id <sp-appId> --client-secret '<sp-password>' \
  --ts-authkey '<tskey>' --ts-hostname formae-bootstrap \
  --api-user formae --api-password-hash '<hash>' --db-password '<dbpass>' \
  --ssh-public-key "$(cat ~/.ssh/id_ed25519.pub)" --watch

# From a machine on the same tailnet:
azure/scripts/write-bootstrap-profile.sh --profile bootstrap --access tailnet \
  --fqdn formae-bootstrap.<your-tailnet>.ts.net --user formae --password '<password>'
formae status agent --profile bootstrap
```

## Upgrading

Upgrade the agent by re-applying with a newer `--formae-image` (the version knob) — same flags
as your original apply (including the **same** `--db-password`). **Keep this local install and
its datastore:** it holds your agent's own infrastructure in state, so re-applying to upgrade
depends on it.

## Design notes / current limitations

- **Secrets path.** The azure plugin cannot yet attach a managed identity to the VM, so the
  agent authenticates with the service principal, and all secrets reach the VM inside the
  CustomScript extension's `protectedSettings` (write-only, encrypted by Azure, never returned
  by the API) instead of being fetched from a Key Vault at boot. When the plugin gains a VM
  identity property, this moves to Key Vault + managed identity.
- **Egress public IP.** The VM carries a public IP in *both* modes: Azure retired default
  outbound access for new VMs and the plugin has no NAT Gateway resource yet. In `tailnet`
  mode no NSG inbound rule exists, so nothing can reach the VM from the internet.
- **tsnet identity (`tailnet` mode).** The plugin cannot attach a data disk to the VM yet, so
  the tailnet machine identity lives on the OS disk: it survives reboots but **not** VM
  replacement — after a replace, delete the stale node in the Tailscale admin console; the
  agent re-registers via the auth key.
- **Compute is a VM**, not ACI/Container Apps (not in plugin coverage yet) — same shape as the
  GCP bootstrap's GCE VM.

## Teardown

```bash
formae destroy stack formae-bootstrap-azure
formae apply --mode reconcile azure/destroy-target.pkl   # deregister the target
```

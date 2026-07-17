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

- **Local Azure credentials** for the formae agent you run locally to perform the apply. The
  agent's Azure plugin uses the `DefaultAzureCredential` chain, so `az login` on this machine is
  enough (or set `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET`). Restart the local
  agent after setting them. This is separate from the service principal below, which is the identity
  the *remote* agent runs as.
- A **service principal** the remote agent operates Azure with:

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

## Flags

| Flag | Required | Default | Notes |
| --- | --- | --- | --- |
| `--access` | — | `public` | `public` (self-signed HTTPS) or `tailnet` |
| `--location` | — | `eastus` | Azure region. Must accept new customers and offer PostgreSQL Flexible Server + the chosen VM size (see Troubleshooting) |
| `--name` | — | `formae-bootstrap` | Prefix for every resource. **Must be globally unique** — it drives the PostgreSQL server FQDN (`<name>-db.postgres.database.azure.com`) and the public DNS label, both of which collide across subscriptions. Change it if the default is taken |
| `--size` | — | `small` | `small`/`medium`/`large`/`xlarge` → Dsv6 VM sizes (see `sizing.pkl`; fresh subscriptions get 0 vCPU quota on B-series and v5 families, so Dsv6 is the default) |
| `--subscription-id` | yes | — | Target subscription |
| `--tenant-id` / `--client-id` / `--client-secret` | yes | — | Remote agent's service principal |
| `--api-user` / `--api-password-hash` | yes | `formae` / — | Basic-auth credential (`gen-api-credential.sh` prints the hash) |
| `--db-password` | yes | — | Stable Postgres admin password. Reuse the **same** value on every re-apply |
| `--ssh-public-key` | yes | — | Admin key on the VM (no inbound SSH rule is opened; see Troubleshooting) |
| `--allowed-cidr` | — | `*` | `public` mode only: source CIDR allowed to the agent API. Tighten for production |
| `--ts-authkey` / `--ts-hostname` | tailnet | — | `tailnet` mode only: reusable auth key tagged `tag:formae`, and the tailnet hostname |
| `--vnet-cidr` / `--subnet-cidr` | — | `10.100.0.0/16` / `10.100.1.0/24` | Address space |
| `--formae-image` | — | pinned in `vars.pkl` | Agent image; bump to upgrade |

## Troubleshooting

- **No inbound SSH.** The NSG opens only the agent API port (`public` mode) or nothing
  (`tailnet` mode); Azure's default rules deny all other inbound. The SSH key is required by Azure
  but there is no public path to port 22. To debug a VM that won't boot the agent, use
  `az serial-console connect -g <name>-rg -n <name>-agent` or the portal's Serial Console.
- **`--name` already taken.** A failed create on `<name>-db` (PostgreSQL server name is globally
  unique) or the public DNS label means the default `formae-bootstrap` is in use. Re-run with a
  unique `--name`.
- **Region rejects the deployment.** Fresh subscriptions are restricted in many regions. If apply
  fails with `LocationIsOfferRestricted` (Postgres), `RequestDisallowedByAzure` (region closed to
  new customers), or a `standard*Family` quota error (VM size), pick another region or request a
  quota increase.

## Teardown

Destroy the stack, then deregister the target:

```bash
formae destroy --query "stack:formae-bootstrap-azure"
formae apply --mode destroy azure/destroy-target.pkl
```

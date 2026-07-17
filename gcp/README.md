# Formae agent on GCP

One command stands up a production **formae agent** on GCP — a VPC, a GCE VM running
the agent container, and a Cloud SQL PostgreSQL database — secure by default. Two
access modes via `--access` (there is no plaintext option):

- **`public`** — a global external HTTPS load balancer terminating HTTPS with **your**
  certificate (`--cert-file`/`--key-file`, or a pre-created `--cert-name`), with HTTP
  basic auth on top. The agent VM never gets a public IP; the load balancer is the only
  ingress. GCP's analog of the AWS `alb` mode.
- **`tailnet`** (default) — private, reached only over your Tailscale tailnet (no public
  ingress), serving a trusted `*.ts.net` certificate, with HTTP basic auth on top.

> **Version dependency.** `--access public` requires a GCP plugin that implements
> `GCP::Compute::InstanceGroup` VM membership (the `instances` field) and the widened
> `SslCertificate.privateKey`. Until those land in a published release, `gcp/PklProject`
> points at a **local** plugin checkout; see [Version dependency](#version-dependency).

Formae runs as a client and an agent: you use your local install to provision the
agent's permanent home in the cloud, then point your CLI at it with a profile and hand
off.

## How it works

A long-running **GCE VM** (Container-Optimized OS) is the analog of the AWS ECS Fargate
task. It runs two containers via a startup script:

- the **formae agent**, which joins your tailnet (embedded tsnet), serves a trusted
  `*.ts.net` cert + basic auth, and persists its tailnet machine identity to an attached
  **persistent disk** (the GCP analog of the AWS tailnet EFS volume);
- the **Cloud SQL Auth Proxy**, which the agent connects to on `127.0.0.1:5432`,
  authenticating to Cloud SQL with the VM's service account (`roles/cloudsql.client`) —
  no VPC private-service-access needed.

The VM sits in a **private subnet** with **Cloud NAT** for egress (no external IP).
Secrets — the DB password, the API basic-auth bcrypt hash, and the Tailscale auth key —
live in **Secret Manager** and are fetched by the VM at boot via its metadata token;
they are never placed in instance metadata.

## Prerequisites

- A GCP project, with these APIs enabled:
  ```bash
  gcloud services enable compute.googleapis.com sqladmin.googleapis.com \
    secretmanager.googleapis.com --project <project>
  ```
- Local credentials for the formae agent's GCP plugin — either
  `gcloud auth application-default login` (user ADC, simplest) or
  `export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json`. **(Re)start the
  agent after setting them** so the plugin picks them up; without credentials the
  GCP plugin fails every call with `invalid_grant` / `invalid_rapt`.
- A reusable **Tailscale auth key** tagged `tag:formae`, with HTTPS certificates enabled
  on your tailnet.

## Quickstart

```bash
git clone https://github.com/platform-engineering-labs/formae-bootstrap.git
cd formae-bootstrap

# Generate the basic-auth credential + a DB password. Keep the printed values.
gcp/scripts/gen-api-credential.sh
```

**`tailnet`** (default — private, over your Tailscale tailnet):

```bash
formae apply --mode reconcile gcp/bootstrap.pkl \
  --project <project> \
  --api-user formae --api-password-hash '<hash>' \
  --db-password '<db-password>' \
  --ts-authkey '<tskey>' --ts-hostname formae-bootstrap \
  --watch

# From a machine on the same tailnet:
gcp/scripts/write-bootstrap-profile.sh --profile bootstrap \
  --fqdn formae-bootstrap.<your-tailnet>.ts.net --user formae --password '<password>'
formae status agent --profile bootstrap
```

**`public`** (public HTTPS load balancer with your certificate):

```bash
# Bring your own PEM cert + key (self-signed is fine for a smoke test):
formae apply --mode reconcile gcp/bootstrap.pkl --access public \
  --project <project> \
  --cert-file ./fullchain.pem --key-file ./privkey.pem \
  --domain formae.example.com \
  --api-user formae --api-password-hash '<hash>' \
  --db-password '<db-password>' \
  --watch

# ...or reference a certificate you pre-created in the project:
#   --cert-name my-existing-cert   (instead of --cert-file/--key-file)

# Point your DNS A record at the reserved global address the stack prints, then:
curl -u formae:'<password>' https://formae.example.com/api/v1/agent
# health check is basic-auth-exempt:
curl https://formae.example.com/api/v1/health
```

Pass **either** `--cert-name <existing>` **or** both `--cert-file` and `--key-file`
(paths are read at apply time; give absolute paths or paths relative to `gcp/`). The
private key is stored **opaque** — it never lands readably in plans or state.

## Flags

| Flag | Required | Default | Purpose |
| --- | --- | --- | --- |
| `--project` | yes | — | GCP project ID |
| `--access` | no | `tailnet` | `public` (HTTPS LB) or `tailnet` (Tailscale) |
| `--api-password-hash` | yes (both modes) | — | bcrypt hash from `gen-api-credential.sh` |
| `--db-password` | yes (both modes) | — | stable Cloud SQL postgres password |
| `--cert-name` | public: one of these two | — | name of a pre-created global `SslCertificate` |
| `--cert-file` + `--key-file` | public: one of these two | — | PEM cert chain + key; creates a `SELF_MANAGED` cert in-stack (key stored opaque) |
| `--domain` | no (public) | — | hostname clients connect to; point its DNS at the printed address |
| `--ts-authkey` | yes (tailnet) | — | reusable Tailscale auth key (`tag:formae`) |
| `--ts-hostname` | no (tailnet) | `--name` | tailnet MagicDNS hostname |
| `--name` | no | `formae-bootstrap` | resource name prefix |
| `--region` / `--zone` | no | `us-central1` / `us-central1-a` | location |
| `--size` | no | `small` | agent VM size (small/medium/large/xlarge → GCE machine type) |
| `--formae-image` | no | pinned | agent image (version knob) |
| `--subnet-cidr` | no | `10.100.1.0/24` | private subnet range |

Cross-mode flags are rejected fast: `--cert-*`/`--domain` throw under `tailnet`, and
`--ts-authkey`/`--ts-hostname` throw under `public`, with a clear message.

### Public mode notes

- **DNS.** The stack reserves a global anycast address and prints it; point your domain's
  `A` record at it. For a smoke test without DNS, use `curl --resolve <domain>:443:<ip>`.
- **Firewall.** Google's health-check + front-end ranges `130.211.0.0/22` and
  `35.191.0.0/16` are admitted to the formae port (`49684`), scoped to the agent VM's
  service account — backends never report healthy without this rule.
- **Certificate rotation.** GCP `SslCertificate` resources are **immutable** (all fields
  create-only). To rotate, apply with a new `--cert-name` (or a changed cert file that
  yields a new resource name) and re-apply; there is no in-place cert update.

## Upgrading

Re-apply with a newer `--formae-image` (same flags). **Keep this local install and its
datastore** — it holds the agent's own infrastructure in state, so upgrades depend on it.

## Teardown

Destroy the stack, then deregister the target:

```bash
formae destroy --query "stack:formae-gcp-bootstrap"
formae apply --mode destroy gcp/destroy-target.pkl
```

> **Note:** you currently need to run the `destroy` **twice**. The first pass
> deletes the agent VM but its Cloud SQL Auth Proxy connections take a moment to
> drain; the `formae` database delete then fails with
> `pq: database "formae" is being accessed by other users`. Re-running `destroy`
> once the sessions have been reaped completes the teardown. Tracked in
> [issue #4](https://github.com/platform-engineering-labs/formae-bootstrap/issues/4).

## Version dependency

`--access public` depends on GCP plugin features added in the
`feat/instance-group-membership` branch:

- `GCP::Compute::InstanceGroup.instances` — VM membership reconcile (the backend group
  must actually contain the agent VM);
- `GCP::Compute::SslCertificate.privateKey` widened to accept an opaque-wrapped value.

Until those ship in a published hub release, `gcp/PklProject` points `["gcp"]` at a
**local checkout** of that plugin branch. Before merging a public-mode change, cut the
plugin dev tag (`0.1.9-dev.0` or later) and switch the pin to:

```pkl
["gcp"] { uri = "package://hub.platform.engineering/plugins/gcp/schema/pkl/gcp/gcp@0.1.9-dev.0" }
```

The `tailnet` mode has no such dependency and works against the current published plugin.

## Validation status

`pkl eval` and `formae apply --simulate` are clean. A live apply created 15/19 resources
including the running VM (network, NAT, disks, secrets, service account, IAM bindings all
succeeded, in correct dependency order). Two blockers stop a full end-to-end run in the
test environment; both are plugin/environment issues, not the forma:

1. **Cloud SQL.** The test org enforces `constraints/sql.restrictPublicIp`, which rejects
   the public-IP + Auth-Proxy approach. The private-IP alternative needs Private Service
   Access (a `servicenetworking` VPC-peering connection), which the GCP plugin does not
   implement yet. Until the plugin supports PSA (or the org allows public IP), point the
   agent at an **existing** database instead.
2. **Re-apply idempotency.** network/subnetwork/disk references don't round-trip on read
   (`.res.selfLink` renders a full `https://…` URL but GCP stores the `projects/…` path;
   a boot-disk `sourceImage` *family* resolves to a specific image), so reconcile computes
   spurious **replaces** of the subnet + boot disk, which fail while the VM is using them.
   A plugin read-normalization fix is needed for clean upgrades.

The **VM runtime path** (COS startup script: secret fetch, tsnet disk mount, Cloud SQL
proxy, agent container on the tailnet) was not reached end-to-end because the DB never
came up; it still needs a first real run once the Cloud SQL blocker is resolved.

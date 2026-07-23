# Formae agent on GCP

One command stands up a production **formae agent** on GCP — a VPC, a GCE VM running
the agent container, and a Cloud SQL PostgreSQL database — secure by default. Two
access modes via `--access` (there is no plaintext option):

- **`public`** — a global external HTTPS load balancer terminating HTTPS, with HTTP
  basic auth on top. The agent VM never gets a public IP; the load balancer is the only
  ingress. GCP's analog of the AWS `alb` mode. Three ways to supply the certificate:
  `--domain` (Google-managed, auto-provisioned + auto-renewed — recommended), a pre-created
  `--cert-name`, or your own PEM via `--cert-file`/`--key-file`.
- **`tailnet`** (default) — private, reached only over your Tailscale tailnet (no public
  ingress), serving a trusted `*.ts.net` certificate, with HTTP basic auth on top.

Orthogonal to `--access` is **`--compute`**: `vm` (default — the GCE VM above) or
`cloudrun` (a serverless Cloud Run service, no VM). `--compute cloudrun` is always
public and reuses the same external HTTPS LB — see
[Cloud Run compute mode](#cloud-run-compute-mode---compute-cloudrun).

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

**`public`** (public HTTPS load balancer). Recommended: a **Google-managed certificate** —
pass `--domain` and Google provisions and auto-renews a publicly-trusted cert. No cert
files, no renewal to manage:

```bash
formae apply --mode reconcile gcp/bootstrap.pkl --access public \
  --project <project> \
  --domain formae.example.com \
  --api-user formae --api-password-hash '<hash>' \
  --db-password '<db-password>' \
  --watch
```

Then point `formae.example.com`'s DNS **A record at the reserved global address the stack
prints**. The managed cert stays `PROVISIONING` until DNS resolves to the LB and Google
validates ownership (~15–60 min); HTTPS works once it goes `ACTIVE`. Verify:

```bash
curl -u formae:'<password>' https://formae.example.com/api/v1/agent   # 200 through basic auth
curl https://formae.example.com/api/v1/health                          # 200, auth-exempt
curl https://formae.example.com/api/v1/agent                           # 401 without -u
```

Alternatives to `--domain`:
- **Pre-created cert**: `--cert-name my-existing-cert` (e.g. a Certificate Manager / classic
  SSL cert you already manage).
- **Bring your own PEM** ([self-managed cert](https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/self-managed-certs)):
  `--cert-file ./fullchain.pem --key-file ./privkey.pem` (e.g. a Let's Encrypt cert you
  issued with certbot). Paths are read at apply time (absolute, or relative to `gcp/`);
  the private key is stored opaque and never lands readably in plans/state.

Pass exactly **one** of `--domain`, `--cert-name`, or `--cert-file`+`--key-file`.

### Bring your own certificate

Two ways to use your own certificate (any CA — a Let's Encrypt `fullchain.pem`/`privkey.pem`,
or a self-signed pair for testing). Both create/reference a GCP
[self-managed SSL certificate](https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/self-managed-certs).

**A. Let the bootstrap create it (`--cert-file`) — simplest:**
```bash
formae apply --mode reconcile gcp/bootstrap.pkl --access public \
  --project <project> --cert-file ./fullchain.pem --key-file ./privkey.pem \
  --api-user formae --api-password-hash '<hash>' --db-password '<pw>' --watch
```
The bootstrap uploads your PEM as a `SELF_MANAGED` `GCP::Compute::SslCertificate` in-stack
(private key stored opaque).

**B. Import it yourself, then reference it (`--cert-name`):**
```bash
# generate (self-signed example; use your real CA cert in production)
openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
  -keyout key.pem -out cert.pem -subj "/CN=formae.example.com"

# import into GCP
gcloud compute ssl-certificates create my-cert \
  --certificate=cert.pem --private-key=key.pem --global --project <project>

# reference it (pass the full selfLink, not a bare name)
CERT=$(gcloud compute ssl-certificates describe my-cert --global \
  --project <project> --format='value(selfLink)')
formae apply --mode reconcile gcp/bootstrap.pkl --access public \
  --project <project> --cert-name "$CERT" \
  --api-user formae --api-password-hash '<hash>' --db-password '<pw>' --watch
```

A self-managed certificate serves immediately (no domain-validation wait, unlike
`--domain`). Point your DNS at the reserved LB address, or test without DNS:
```bash
IP=$(gcloud compute forwarding-rules describe <name>-fr --global --project <project> --format='value(IPAddress)')
curl -k --resolve formae.example.com:443:$IP https://formae.example.com/api/v1/health   # 200
```
(`-k` only because a self-signed cert isn't publicly trusted; a real CA cert needs no `-k`.)

> **Note on `--cert-name`:** pass the certificate's full **selfLink**
> (`https://www.googleapis.com/compute/v1/projects/.../global/sslCertificates/NAME`), not a
> bare name — the target HTTPS proxy resolves the resource URL, not a short name.

## Cloud Run compute mode (`--compute cloudrun`)

`--compute cloudrun` runs the agent as a **serverless Cloud Run service** instead of a GCE
VM — no OS, disk, or startup script to manage. It is always **public**: served at your
custom domain through the **same external HTTPS LB** as `--access public`, via a
**serverless NEG** backend, with the `run.app` URL locked to the load balancer
(`ingress = INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`) and HTTP basic auth on top. It reuses
the same private Cloud SQL substrate.

```bash
formae apply --mode reconcile gcp/bootstrap.pkl --compute cloudrun \
  --project <project> \
  --domain formae.example.com \
  --api-user formae --api-password-hash '<hash>' \
  --db-password '<db-password>' \
  --watch
```

Certificate options are identical to `--access public`: `--domain` (Google-managed),
`--cert-name`, or `--cert-file`+`--key-file`. Point the domain's DNS **A record at the
reserved global address the stack prints**, then verify exactly as in the public
Quickstart (`/api/v1/health` → 200; agent API → 401 without `-u`, 200 with).

Key characteristics:

- **Single always-on instance.** `minInstanceCount = maxInstanceCount = 1` and
  `cpuIdle = false`. The agent is a single-actor daemon running background sync (300s) and
  discovery (600s) off-request — two instances collide on one datastore, and scale-to-zero
  would stop the background loops. **This is not a scalable deployment and won't become
  one.** Cost is roughly the small VM; the win is ops, not price.
- **Private Cloud SQL over Direct VPC egress.** The service attaches to the bootstrap
  subnet with `vpcAccess.egress = PRIVATE_RANGES_ONLY` (only RFC1918 goes over the VPC, so
  Cloud Run needs no NAT of its own) and reaches the private-IP instance through the
  built-in Cloud SQL connector volume; the agent connects over the
  `/cloudsql/<connName>` unix socket (`sslmode=disable`).
- **Config as a mounted secret.** Cloud Run has no shell step to expand `$FORMAE_*`, so the
  whole agent config is rendered by Pkl (secret values inlined), stored as a Secret Manager
  secret, mounted as a volume, and passed with `--config`. No config plaintext in the
  service spec.
- **Sizing.** `--size` maps to a Cloud-Run-legal cpu/memory pair (small `1000m`/`2Gi` …
  xlarge `8000m`/`16Gi`), distinct from the GCE machine-type map.
- **`--access tailnet`, `--ts-authkey`, `--ts-hostname` are rejected** under
  `--compute cloudrun` (Cloud Run + tailnet is unsupported).
- **Public IAM binding required.** The serverless NEG forwards LB traffic to Cloud
  Run unauthenticated, so the service is granted `allUsers` → `roles/run.invoker`
  (a `GCP::CloudRun::ServiceIamMember`) or it 403s every request. Reachability is
  still locked to the LB by `ingress=INTERNAL_LOAD_BALANCER`, and the agent's HTTP
  basic auth is the real gate. **Org-policy caveat:** projects enforcing
  `constraints/iam.allowedPolicyMemberDomains` (domain-restricted sharing) forbid
  `allUsers` and need an exception for this binding, or the LB path returns 403.

## Flags

| Flag | Required | Default | Purpose |
| --- | --- | --- | --- |
| `--project` | yes | — | GCP project ID |
| `--compute` | no | `vm` | `vm` (GCE VM) or `cloudrun` (serverless Cloud Run, always public) |
| `--access` | no | `tailnet` (vm) / `public` (cloudrun) | `public` (HTTPS LB) or `tailnet` (Tailscale); empty derives from `--compute` |
| `--api-password-hash` | yes (both modes) | — | bcrypt hash from `gen-api-credential.sh` |
| `--db-password` | yes (both modes) | — | stable Cloud SQL postgres password |
| `--domain` | public: one of these three | — | Google-managed cert for this hostname (auto-provisioned + renewed); also the DNS name to point at the LB |
| `--cert-name` | public: one of these three | — | name of a pre-created global `SslCertificate` |
| `--cert-file` + `--key-file` | public: one of these three | — | PEM cert chain + key; creates a `SELF_MANAGED` cert in-stack (key stored opaque) |
| `--ts-authkey` | yes (tailnet) | — | reusable Tailscale auth key (`tag:formae`) |
| `--ts-hostname` | no (tailnet) | `--name` | tailnet MagicDNS hostname |
| `--name` | no | `formae-bootstrap` | resource name prefix |
| `--region` / `--zone` | no | `us-central1` / `us-central1-a` | location |
| `--size` | no | `small` | agent size (small/medium/large/xlarge → GCE machine type, or a Cloud Run cpu/memory pair under `--compute cloudrun`) |
| `--formae-image` | no | pinned | agent image (version knob) |
| `--subnet-cidr` | no | `10.100.1.0/24` | private subnet range |

Cross-mode flags are rejected fast: `--cert-*`/`--domain` throw under `tailnet`,
`--ts-authkey`/`--ts-hostname` throw under `public` (and under `--compute cloudrun`), and
`--compute cloudrun` with `--access tailnet` throws — each with a clear message.

### Public mode notes

- **Managed cert (recommended).** With `--domain`, the cert is a Google-managed
  `SslCertificate`: publicly trusted, auto-provisioned, and auto-renewed. It only goes
  `ACTIVE` once the domain's DNS `A` record resolves to the LB and Google validates
  ownership (~15–60 min). No self-signed certs are offered.
- **DNS.** The stack reserves a global anycast address and prints it; point your domain's
  `A` record at it. (A managed cert requires real DNS — it cannot validate against
  `--resolve` or a domain you don't control.)
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

`--access public` needs **GCP plugin ≥ 0.1.9**, pinned in `gcp/PklProject`:

```pkl
["gcp"] { uri = "package://hub.platform.engineering/plugins/gcp/schema/pkl/gcp/gcp@0.1.9" }
```

0.1.9 carries the features public mode relies on: `GCP::Compute::InstanceGroup.instances`
(VM membership), `SslCertificate.privateKey` opaque-wrapping, and SELF_MANAGED
`selfManaged` nesting (for `--cert-file`). The `tailnet` mode has no such dependency.

**`--compute cloudrun` needs a newer GCP plugin** than 0.1.9: it uses
`GCP::CloudRun::Service.template.vpcAccess` (Direct VPC egress), secret-volume `items`
(config mount), and a `Resolvable` `SecretVolumeSource.secret` — all added in
[formae-plugin-gcp#87](https://github.com/platform-engineering-labs/formae-plugin-gcp/pull/87).
Bump the `gcp@…` pin above to the release that includes #87 before using
`--compute cloudrun`.

## Validation status

**`--access public` is validated live, end to end (2026-07-20).** Deployed to a real
project with a Google-managed certificate for a real domain: 29/29 resources created,
the global external load balancer served **trusted HTTPS** (managed cert `ACTIVE`),
`/api/v1/health` returned `200` unauthenticated, and the agent API returned `401` without
credentials and served through HTTP basic auth with them. `formae destroy` cleaned up
(two passes — the Cloud SQL + PSA peering teardown is eventually consistent; see the
Teardown note).

**All three certificate options are supported (bring-your-own or managed):**
- `--domain` — Google-managed certificate, auto-provisioned and auto-renewed. The path
  exercised in the live run. Recommended.
- `--cert-name` — reference a certificate you pre-created in the project.
- `--cert-file` + `--key-file` — **bring your own PEM** (e.g. a Let's Encrypt certificate
  you issued with certbot, or any CA). This is GCP's
  [self-managed SSL certificate](https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/self-managed-certs)
  flow: your uploaded certificate + private key become a `SELF_MANAGED`
  `GCP::Compute::SslCertificate` in-stack, with the private key stored opaque. The
  SELF_MANAGED `selfManaged` nesting fix
  ([formae-plugin-gcp#81](https://github.com/platform-engineering-labs/formae-plugin-gcp/pull/81))
  is merged to plugin `main`.

`pkl eval` / `formae apply --simulate` are clean for `tailnet` (default, unchanged) and
all three public certificate paths.

**`--compute cloudrun` is render-validated, live pending.** Against the plugin schema with
[#87](https://github.com/platform-engineering-labs/formae-plugin-gcp/pull/87), the render
matrix passes: all four `vm` cells are byte-identical to pre-change (zero regression); the
three `cloudrun` cert cells render the expected set (Cloud Run service with min=max=1,
`cpuIdle=false`, `ingress=INTERNAL_LOAD_BALANCER`, Direct VPC egress, Cloud SQL connector
volume, config-secret volume; serverless NEG; reused LB chain; no VM/instance-group/health
-check/guest-firewall); and the illegal combinations throw. The **live** end-to-end run
(real project + domain + cert) is the remaining gate, and depends on the plugin release
that carries #87.

The earlier tailnet-mode blockers (private-IP Cloud SQL, re-apply drift) are resolved on
plugin `main` (Private Service Access support + read-back normalization landed).

The **VM runtime path** (COS startup script: secret fetch, tsnet disk mount, Cloud SQL
proxy, agent container on the tailnet) was not reached end-to-end because the DB never
came up; it still needs a first real run once the Cloud SQL blocker is resolved.

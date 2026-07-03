# Formae agent on GCP

One command stands up a production **formae agent** on GCP — a VPC, a GCE VM running
the agent container, and a Cloud SQL PostgreSQL database — secure by default, reached
privately over your Tailscale tailnet.

- **`tailnet`** — private, reached only over your Tailscale tailnet (no public ingress),
  serving a trusted `*.ts.net` certificate, with HTTP basic auth on top.

This mirrors the AWS `tailnet` mode. A **public HTTPS** mode (the AWS `alb` equivalent)
is not offered yet — see [Not yet supported](#not-yet-supported).

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
- Local credentials that can create the above (a service-account key or
  `gcloud auth application-default login`).
- A reusable **Tailscale auth key** tagged `tag:formae`, with HTTPS certificates enabled
  on your tailnet.

> **Local plugin dependency (temporary).** Until the GCP plugin is published,
> `gcp/PklProject` points `@gcp` at the plugin's schema on disk via a local path
> dependency. Edit that path to your checkout of
> `platform-engineering-labs/formae-plugin-gcp` (schema/pkl), then run
> `pkl project resolve` in `gcp/`. Swap it for a `package://…/gcp@X.Y.Z` uri once the
> plugin is released.

## Quickstart

```bash
git clone https://github.com/platform-engineering-labs/formae-bootstrap.git
cd formae-bootstrap

# Generate the basic-auth credential + a DB password. Keep the printed values.
gcp/scripts/gen-api-credential.sh
```

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

## Flags

| Flag | Required | Default | Purpose |
| --- | --- | --- | --- |
| `--project` | yes | — | GCP project ID |
| `--api-password-hash` | yes | — | bcrypt hash from `gen-api-credential.sh` |
| `--db-password` | yes | — | stable Cloud SQL postgres password |
| `--ts-authkey` | yes | — | reusable Tailscale auth key (`tag:formae`) |
| `--ts-hostname` | no | `--name` | tailnet MagicDNS hostname |
| `--name` | no | `formae-bootstrap` | resource name prefix |
| `--region` / `--zone` | no | `us-central1` / `us-central1-a` | location |
| `--size` | no | `small` | agent VM size (small/medium/large/xlarge → GCE machine type) |
| `--formae-image` | no | pinned | agent image (version knob) |
| `--subnet-cidr` | no | `10.100.1.0/24` | private subnet range |

## Upgrading

Re-apply with a newer `--formae-image` (same flags). **Keep this local install and its
datastore** — it holds the agent's own infrastructure in state, so upgrades depend on it.

## Teardown

Destroy the stack, then deregister the target:

```bash
formae destroy --stack formae-bootstrap
formae apply --mode destroy gcp/destroy-target.pkl
```

## Not yet supported

- **Public HTTPS mode** (AWS `alb` equivalent). A GCE-VM-backed external HTTPS load
  balancer needs instance-group *membership* management (add the VM to an unmanaged
  instance group), which the GCP plugin does not implement yet. The serverless NEG and
  managed SSL certificate resources exist; only VM membership is missing.

## Validation status

The forma evaluates cleanly (`pkl eval`) and uses only merged, conformance-tested plugin
resources. The **VM runtime path** — the Container-Optimized OS startup script that
fetches secrets, mounts the tsnet identity disk, starts the Cloud SQL Auth Proxy, and
launches the agent container on the tailnet — has not yet been exercised by a live
`formae apply` end-to-end; treat it as needing a first real apply to shake out.

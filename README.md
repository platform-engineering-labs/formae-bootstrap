# formae-bootstrap

Stand up a self-hosted **formae agent** on a cloud provider. Each provider lives in its own
directory.

## How it works

Formae is a **client + agent** system. You run both locally to start, use that local install
to provision the agent's own permanent home in the cloud, then point your local CLI at the
now-remote agent via a profile and hand off. From then on the remote agent owns your
infrastructure — reconciling, discovering, and syncing continuously — while your laptop is
just a client that talks to it. See [`aws/README.md`](aws/README.md#how-this-works) and the
[architecture overview](https://docs.formae.io) for the full model.

## AWS

[`aws/`](aws/) installs a production formae agent on ECS Fargate, backed by RDS PostgreSQL
(or your own database). One command, two **secure** access modes — there is no plaintext
option:

- **`alb`** — public, internet-facing ALB terminating HTTPS with your own ACM certificate,
  plus HTTP basic auth.
- **`tailnet`** — private, reached only over your Tailscale tailnet (no public ingress),
  serving a trusted `*.ts.net` certificate, with basic auth on top.

Full instructions in [`aws/README.md`](aws/README.md).

## Azure

[`azure/`](azure/) installs a production formae agent on a VM, backed by Azure Database for
PostgreSQL Flexible Server reached through a private endpoint (no public database access).
One command, two **secure** access modes — there is no plaintext option:

- **`public`** — the agent terminates HTTPS itself with a self-signed certificate, served at
  a stable `<name>.<location>.cloudapp.azure.com` FQDN, plus HTTP basic auth.
- **`tailnet`** — private, reached only over your Tailscale tailnet (no public ingress),
  serving a trusted `*.ts.net` certificate, with basic auth on top.

Full instructions in [`azure/README.md`](azure/README.md).

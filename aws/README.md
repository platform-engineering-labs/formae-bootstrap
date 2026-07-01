# Formae agent on AWS

One command stands up a production **formae agent** on AWS — a VPC, an ECS Fargate task, and an
RDS PostgreSQL database — secure by default, in one of two access modes:

- **`alb`** — public, internet-facing ALB terminating HTTPS with **your** ACM certificate, plus
  HTTP basic auth.
- **`tailnet`** — private, reached only over your Tailscale tailnet (no public ingress), serving
  a trusted `*.ts.net` certificate, with basic auth on top.

Formae runs as a client and an agent: you use your local install to provision the agent's
permanent home in the cloud, then point your CLI at it with a profile and hand off.

## Quickstart

```bash
git clone https://github.com/platform-engineering-labs/formae-bootstrap.git
cd formae-bootstrap

# Generate the basic-auth credential — keep the printed password; the hash goes to the apply.
aws/scripts/gen-api-credential.sh
```

**`alb`** (needs a domain you own + an ACM certificate for it):

```bash
formae apply --mode reconcile aws/bootstrap.pkl --access alb --region <region> \
  --cert-arn <acm-arn> --domain agent.example.com \
  --api-user formae --api-password-hash '<hash>' --watch

# Point agent.example.com at the ALB, then:
aws/scripts/write-bootstrap-profile.sh --profile bootstrap \
  --domain agent.example.com --user formae --password '<password>'
formae status agent --profile bootstrap
```

**`tailnet`** (needs a reusable Tailscale auth key tagged `tag:formae`, HTTPS certs enabled):

```bash
formae apply --mode reconcile aws/bootstrap.pkl --access tailnet --region <region> \
  --ts-authkey '<tskey>' --ts-hostname formae-bootstrap \
  --api-user formae --api-password-hash '<hash>' --watch

# From a machine on the same tailnet:
aws/scripts/write-bootstrap-profile.sh --profile bootstrap --access tailnet \
  --fqdn formae-bootstrap.<your-tailnet>.ts.net --user formae --password '<password>'
formae status agent --profile bootstrap
```

## Upgrading

Upgrade the agent by re-applying with a newer `--formae-image` (the version knob) — same flags
as your original apply. **Keep this local install and its datastore:** it holds your agent's own
infrastructure (VPC, database, ECS service) in state, so re-applying to upgrade depends on it.
See [Updating the agent](https://docs.formae.io/en/latest/operations/install-aws-operations/#updating-the-agent-bootstrap).

## Full guide

Prerequisites (ACM certificate, Tailscale setup), every flag, sizing, and day-2 operations
(updating, shelling in, teardown, tuning) are in the
**[AWS Bootstrap installation guide](https://docs.formae.io/en/latest/operations/install-aws-bootstrap/)**.

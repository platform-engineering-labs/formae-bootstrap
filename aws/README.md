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

### Upgrading an installation created before the generator-drawn password

Installations bootstrapped before this version minted the database password at
evaluation time and pinned it with `setOnce`. A `setOnce` field keeps the value
it was created with, so formae refuses to route a generator through it: the
first re-apply of this version over such an installation is rejected at plan
time, naming the field. The apply changes nothing when refused. Migrate in two
applies, both with your usual flags:

1. Edit `bootstrap.pkl` to the transitional shape: add
   `import "@formae/ext/random.pkl"` back to the import block, change the
   secret's line to
   `secretString = formae.value(random.password(24, false)).opaque`
   (the old line without `.setOnce`), and remove `dbPasswordGen` from the
   manifest. Apply. This re-mints the password once and releases the `setOnce`
   pin; the database follows the new value in the same apply.
2. Revert to this version's `bootstrap.pkl` as shipped and apply again. The
   generator draws, and the secret and database move together; from here on the
   password is generator-owned.
3. Restart the deployed agent so it reads the new password — it receives
   `FORMAE_DB_PASSWORD` at task start, so it keeps using the old one until its
   task is replaced:
   `aws ecs update-service --cluster <name>-cluster --service <name>-service --force-new-deployment`
   (default `<name>` is `formae-bootstrap`).

Run the two applies back to back and restart once at the end: the deployed
agent cannot reach its database from the moment step 1 lands until the restart,
so keep that window short. Your local install, which runs these applies, is
unaffected. Fresh installations need none of this.

## Full guide

Prerequisites (ACM certificate, Tailscale setup), every flag, sizing, and day-2 operations
(updating, shelling in, teardown, tuning) are in the
**[AWS Bootstrap installation guide](https://docs.formae.io/en/latest/operations/install-aws-bootstrap/)**.

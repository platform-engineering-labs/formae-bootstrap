# Formae Bootstrap on AWS

Stands up a formae agent on AWS, VPC, ECS Fargate running the agent, and an
Application Load Balancer for the API, with an RDS PostgreSQL database it either
provisions for you or connects to. The agent reaches Postgres over TCP (5432);
the password is injected at task start from Secrets Manager, so it never lands in
the task definition.

Once it's up, point your local formae CLI at the remote agent. The local SQLite
instance is no longer needed; the remote agent runs discovery and rebuilds its
inventory from what's deployed.

One entrypoint, [`bootstrap.pkl`](bootstrap.pkl), with a `--database` flag:

| `--database` | Provisions |
|--------------|------------|
| `new` (default) | VPC + **RDS PostgreSQL** (generated password) + ECS + ALB + agent |
| `existing` | VPC + ECS + ALB + agent, pointed at a Postgres DB you already run (no DB created) |

## Prerequisites

- formae CLI + AWS plugin installed (`formae plugin install aws`)
- AWS credentials configured (`~/.aws/credentials` or environment variables); pick a profile with `--profile`
- Permissions to create: VPC, RDS, ECS, IAM, ELB, CloudWatch Logs, Secrets Manager

## Deploy

The ALB serves the agent API over **HTTPS by default** with a self-signed certificate.
Pkl can't mint one, so generate it once before applying (the cert files are gitignored):

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout aws/cert.key -out aws/cert.crt \
  -subj "/CN=formae-bootstrap" -addext "subjectAltName=DNS:formae-bootstrap"
```

From scratch (provisions the database; RDS spin-up dominates the wall-clock, ~10 min):

```bash
formae apply --mode reconcile aws/bootstrap.pkl
```

Bring your own database (no DB created; you supply the connection):

```bash
formae apply --mode reconcile aws/bootstrap.pkl \
  --database existing \
  --db-host mydb.abc123.us-east-2.rds.amazonaws.com \
  --db-user myuser --db-name mydb \
  --db-password-secret-arn arn:aws:secretsmanager:us-east-2:<acct>:secret:my-db-pw
```

In `existing` mode `--db-host`, `--db-user`, `--db-name`, and
`--db-password-secret-arn` are required; the apply fails fast if one is missing
rather than silently defaulting (so it can't connect to the wrong database).
`--db-port` defaults to `5432`. If your secret stores JSON (e.g. an RDS-managed
secret), append the key selector to the ARN: `...:secret:my-db-pw:password::`.
The Fargate task runs in the VPC this file creates, so your database must be
reachable from it (a publicly-accessible endpoint, or peer/share this VPC with
the database's).

## Flags

| Flag | Default | Notes |
|------|---------|-------|
| `--database` | `new` | `new` provisions RDS; `existing` connects to your DB |
| `--visibility` | `public` | `public` = internet-facing ALB on `0.0.0.0/0`; `internal` = internal ALB scoped to the VPC CIDR, no public task IPs |
| `--size` | `small` | Fargate size: `small` (0.5 vCPU / 2 GB), `medium` (1/2), `large` (2/4), `xlarge` (4/8) |
| `--region` | `us-east-2` | Region for the apply; subnet AZs derive from it (`<region>a`/`<region>b`) |
| `--aws-profile` | (default creds) | AWS profile for the local apply credentials (named `--aws-profile`, not `--profile`, which formae reserves for its own CLI profiles) |
| `--name` | `formae-bootstrap` | Prefix for all resource names |
| `--vpc-cidr` | `10.100.0.0/16` | VPC CIDR (also scopes the internal-mode SG ingress, keep it tight) |
| `--subnet-cidr-1` / `--subnet-cidr-2` | `10.100.1.0/24` / `10.100.2.0/24` | Public subnet CIDRs; must sit inside `--vpc-cidr` |

`--region` and `--aws-profile` govern the **local apply** credentials (the ones that
build the infrastructure), not the deployed agent, which authenticates via its
ECS task role.

## Security note

The ALB terminates **HTTPS** with a **self-signed** certificate (the `cert.crt` you
generate above), so traffic is encrypted in transit, but the cert is not publicly
trusted: clients must skip verification (see Connect) or trust it explicitly. For a
publicly-trusted endpoint, bring your own domain + an ACM certificate and point the
listener's `certificateArn` at it instead.

`--visibility public` exposes the API on an internet-facing ALB (`0.0.0.0/0`); for
anything real prefer `--visibility internal` (internal ALB scoped to the VPC CIDR, no
public task IPs, reachable over VPN/peering). Authentication (via the `auth-basic`
plugin) is a follow-on and is not wired here yet.

## Connect

Get the ALB DNS name from inventory:

```bash
formae inventory resources --query 'type:AWS::ElasticLoadBalancingV2::LoadBalancer'
```

Point your CLI at the remote agent in `~/.config/formae/formae.conf.pkl`. The ALB
serves HTTPS with a self-signed cert, so set `insecureSkipVerify` (the cert isn't
publicly trusted; omit it once you move to a real domain + ACM cert):

```pkl
cli {
  api {
    url = "https://<alb-dns>"
    port = 49684
    insecureSkipVerify = true
  }
}
```

Verify:

```bash
formae status agent
```

With `--visibility internal` the ALB isn't internet-reachable; run the CLI from
inside the VPC (or over VPN/peering).

The deployed agent's discovery is filtered (via the `app=formae-agent` tag) so it
does not report this stack's own VPC/RDS/ECS/ALB as unmanaged resources.

## Shell into the agent

The agent service runs with ECS Exec enabled (`enableExecuteCommand` on the
service plus the `ssmmessages` channel permissions on the task role), so you can
open a shell in the running container. Fargate has no host to `docker exec` into,
so this is the way in.

Requires the AWS Session Manager plugin installed locally:

```bash
brew install --cask session-manager-plugin    # macOS; see AWS docs for Linux/Windows
```

Then exec in (task id is fetched inline so it survives task rolls):

```bash
aws ecs execute-command --region us-east-2 \
  --cluster formae-bootstrap-cluster \
  --task "$(aws ecs list-tasks --region us-east-2 --cluster formae-bootstrap-cluster --query 'taskArns[0]' --output text)" \
  --container formae-agent --interactive --command /bin/sh
```

Cluster name and region follow `projectName` / `region` in `vars.pkl`.

## Teardown

```bash
formae destroy --mode reconcile aws/bootstrap.pkl                     # new (also destroys the RDS)
# or
formae destroy --mode reconcile aws/bootstrap.pkl --database existing # BYO (leaves your DB untouched)
```

## Configuration

Flags above cover the per-deploy knobs. Edit [`vars.pkl`](vars.pkl) for the
fixed scalars:

| Variable | Default | Description |
|----------|---------|-------------|
| projectName | formae-bootstrap | Prefix for all resource names |
| region | us-east-2 | Default AWS region (override with `--region`) |
| vpcCidr | 10.100.0.0/16 | VPC CIDR block |
| subnetCidr1 / subnetCidr2 | 10.100.1.0/24 / 10.100.2.0/24 | Public subnet CIDRs |
| dbName | formae | Database name (new mode) |
| dbUser | formae | Database master user (new mode) |
| dbInstanceClass | db.t4g.small | RDS instance class (new mode) |
| dbEngineVersion | 16.14 | PostgreSQL engine version (new mode) |
| formaeImage | ghcr.io/platform-engineering-labs/formae:0.86.2 | Formae container image |
| formaePort | 49684 | Agent API port |

## Production hardening

This example favors a cheap, fast stand-up. For production, adjust `bootstrap.pkl` / `vars.pkl`:

- **Multi-AZ:** the DB is single-AZ (`multiAZ = false`), a SPOF. Set `multiAZ = true` for failover
  (roughly doubles RDS cost and deploy time).
- **Storage autoscaling:** `maxAllocatedStorage` is set (100 GB ceiling); raise it for larger inventories.
- **TLS:** replace the self-signed cert with your own domain + an ACM certificate (publicly trusted),
  and drop `insecureSkipVerify` from the CLI config.
- **CIDRs:** `--subnet-cidr-1` / `--subnet-cidr-2` must sit within `--vpc-cidr`; AWS rejects mismatches at apply.

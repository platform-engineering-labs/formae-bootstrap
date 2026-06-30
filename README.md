# formae-bootstrap

Stand up a self-hosted **formae agent** on a cloud provider.
Each provider lives in its own directory.

## AWS

[`aws/`](aws/) stands up a formae agent on ECS Fargate behind an **HTTPS** ALB
(self-signed certificate by default), backed by RDS PostgreSQL. Full instructions in
[`aws/README.md`](aws/README.md).

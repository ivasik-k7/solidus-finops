# Terraform FinOps Framework

A production-grade Terraform framework that provisions a complete FinOps capability stack into a single AWS account, aligned with the [FinOps Foundation Capabilities](https://www.finops.org/framework/capabilities/).

It works for any account that wants reproducible cost allocation, named FinOps KPIs, and audit-defensible automation — not just regulated ones. Defaults lean conservative (KMS CMK, `prevent_destroy` on data, off-by-default destructive Lambdas) so the same code is also valid for SOX / PCI / GDPR / DORA workloads.

This is **not** a thin wrapper around `aws_budgets_budget`. It is a composition of:

- **Cost & Usage data plumbing** — CUR 2.0 + FOCUS 1.0 export, S3 with KMS, Athena workgroup + table partitions, glue catalog.
- **Allocation as code** — AWS Cost Categories defined in HCL so chargeback logic is reproducible, version-controlled, and audit-defensible.
- **Polymorphic budgets** — one `budgets` map with `scope` discriminator (account / service / tag / cost_category); actual and forecasted thresholds, routed to the events bus.
- **Anomaly detection** — Cost Anomaly Detection service-level monitor + subscription wired into the events bus.
- **Tag governance** — AWS Config rules for required tags (chunked over the 6-tag managed-rule limit so nothing is silently dropped), with safe remediation patterns (notify-first, never auto-delete).
- **Optimization services** — Compute Optimizer + Cost Optimization Hub enrollment, surfaced as outputs.
- **Idle resource detection** — Lambda functions for unattached EBS volumes, idle EIPs, orphaned snapshots. **Dry-run by default; off by default.**
- **Instance scheduler** — Tag-driven start/stop for non-production environments. **Opt-in by tag, not opt-out; off by default.**
- **Savings coverage reporting** — Lambda that queries Cost Explorer for RI/SP coverage and utilization, reports to the events bus.
- **Events bus** — single SNS topic that all modules publish to. Optional Slack/Teams chat notifier (webhooks held in Secrets Manager, fetched at runtime), KMS-encrypted, with 7-year log retention.
- **Lambda safety net** — every Lambda has a dead-letter queue plus CloudWatch error and DLQ-depth alarms wired to the events bus.

## Why this exists

Most "FinOps Terraform modules" you find online are toys: one budget, one SNS topic, no audit trail, no encryption, no thought given to chargeback reproducibility. This framework was built with four assumptions:

1. **Someone will ask you, a year from now, to reproduce how cost was allocated to a specific team / business unit / product for a specific month.** Allocation logic therefore lives in code, in version control, with full git history. (Regulator, finance lead, internal audit — same need either way.)
2. **An account owner cannot tolerate an automation that deletes important data because someone forgot a tag.** Every destructive automation is off by default, dry-run when enabled, requires explicit per-resource-type opt-in, and respects exception tags.
3. **Encryption at rest is the right default.** Every S3 bucket uses KMS CMKs (not SSE-S3), every SNS topic is encrypted, every Lambda log group is encrypted, chat webhooks live in Secrets Manager rather than env vars.
4. **Silent failure is the worst failure.** Every Lambda has a DLQ + a CloudWatch error alarm + a DLQ-depth alarm routed to the events bus.

## Repository layout

```
.
├── README.md                   # This file
├── ARCHITECTURE.md             # How the modules fit together; data flow diagram
├── GETTING_STARTED.md          # Step-by-step first deployment
├── TFE_SETUP.md                # Terraform Enterprise workspace configuration
├── versions.tf                 # Required providers and Terraform version
├── providers.tf                # AWS provider config (no credentials — TFE-managed)
├── variables.tf                # Top-level input variables
├── locals.tf                   # Computed locals (tags, naming)
├── main.tf                     # Module composition
├── outputs.tf                  # Outputs surfaced to other workspaces
├── terraform.auto.tfvars.example
│
├── modules/
│   ├── cost-data-exports/      # CUR 2.0 + FOCUS export + Athena
│   ├── budgets/                # Polymorphic budgets (account/service/tag/cost_category)
│   ├── anomaly-detection/      # Cost Anomaly Detection
│   ├── cost-categories/        # Allocation rules as code
│   ├── tag-governance/         # Config rules + Lambda for required tags
│   ├── optimization-services/  # Compute Optimizer, Cost Opt Hub
│   ├── alerting/               # Events SNS topic + Slack/Teams notifier (Secrets Manager)
│   ├── idle-resource-cleanup/  # EBS, EIP, snapshot Lambdas (dry-run, off by default)
│   ├── instance-scheduler/     # Tag-driven start/stop (opt-in, off by default)
│   └── savings-coverage-reporter/  # RI/SP coverage Lambda
│
└── examples/
    ├── production/             # Full FinOps capability stack ("Run" phase)
    └── minimal/                # Smallest viable deployment ("Crawl" phase)
```

## Quick start

1. Copy `terraform.auto.tfvars.example` to `terraform.auto.tfvars` and fill in your values.
2. In your TFE workspace, set the following sensitive variables:
   - `slack_webhook_url` (if using Slack alerting)
   - `teams_webhook_url` (if using Teams alerting)
3. Run `terraform plan` and review.
4. `terraform apply`.

See [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) for the full walk-through, including IAM bootstrap requirements for the TFE workspace's AWS credentials.

## Diagrams

Architecture diagrams live under [diagrams/](diagrams/), generated with the Python [`diagrams`](https://diagrams.mingrammer.com/) library (Graphviz, real AWS icons). Source is Python, outputs are PNG + SVG, all committed:

- [diagrams/framework_structure.py](diagrams/framework_structure.py) → [framework-structure.png](diagrams/framework-structure.png) / [.svg](diagrams/framework-structure.svg) — modules grouped by FinOps Foundation Capability domain, with the events-bus flow
- [diagrams/aws_architecture.py](diagrams/aws_architecture.py) → [aws-architecture.png](diagrams/aws-architecture.png) / [.svg](diagrams/aws-architecture.svg) — AWS services and how they connect, high-level

Render locally:
```bash
pip install -r diagrams/requirements.txt   # plus graphviz at the OS level
cd diagrams && python framework_structure.py && python aws_architecture.py
```

## Deployment phases

The framework is designed to be adopted in stages — see [docs/PHASES.md](docs/PHASES.md) for the FinOps Foundation Crawl / Walk / Run model mapped to concrete enable-flags, plus the exit criteria for each phase.

| Phase | Example | What's on |
|---|---|---|
| Crawl | [examples/minimal](examples/minimal/) | Cost data, anomaly detection, free optimization services, email-only alerts |
| Walk | (between the two) | + cost categories, savings-coverage reporter, finops-metrics KPIs, idle-cleanup in dry-run |
| Run | [examples/production](examples/production/) | + instance scheduler, idle-cleanup in act mode, Slack/Teams, tightened KPI alarms |

## What's evolved vs. typical FinOps Terraform

If you already have a FinOps Terraform setup, here is where this framework typically goes further:

| Area | Typical setup | This framework |
|---|---|---|
| Cost data export | CUR v1 | CUR 2.0 **plus** FOCUS 1.0 export side-by-side |
| Allocation logic | In a BI tool, undocumented | Cost Categories defined in HCL, in git, with PR review |
| S3 encryption | SSE-S3 | KMS CMK with key policy for least-privilege access, `prevent_destroy` lifecycle |
| S3 lifecycle | Deep-Archive everything → Athena breaks | Current versions to Glacier Instant Retrieval (still Athena-queryable); noncurrent to Deep Archive |
| Idle resource cleanup | "Delete after 30 days" Lambda | Dry-run by default, off by default, tag-based opt-in, exception-tag honored |
| Instance scheduler | Opt-out (everything stops unless tagged) | Opt-in (nothing stops unless tagged `Schedule=...`), off by default — single untagged prod resource doesn't become an outage |
| Tag remediation | Auto-tag with "untagged" | Flag and notify; never silently mutate someone's resource |
| Tag-rule limits | Silently drop tags past the 6-key managed-rule limit | Chunked into N rules of 6, no silent truncation |
| Budget inputs | Hard-shaped variables per scope | One polymorphic `budgets` map (account/service/tag/cost_category) |
| Budget alerts | Email to one inbox | Events SNS topic, fanned out by Lambda to Slack/Teams + email |
| Chat webhooks | Plaintext env var | Stored in Secrets Manager (CMK-encrypted), fetched at runtime, cached per warm container |
| Lambda failure mode | Silent | Per-Lambda DLQ + CloudWatch error and DLQ-depth alarms routed to the events bus |
| Audit | None | 7-year CMK-encrypted CloudWatch log retention on every Lambda |
| Savings Plans coverage | Manual Cost Explorer check | Scheduled Lambda → events bus report with utilization, coverage, and recommendation deltas |

## Requirements

- Terraform >= 1.6
- AWS provider >= 5.50 (for FOCUS data exports)
- AWS account with permissions listed in `GETTING_STARTED.md`
- (Optional, for full feature set) AWS Business or Enterprise Support plan — required for Trusted Advisor full checks and Compute Optimizer enhanced infrastructure metrics.

## Audit & compliance evidence

Read [docs/COMPLIANCE_NOTES.md](docs/COMPLIANCE_NOTES.md) for:
- What evidence the framework produces (CloudTrail-ready actions, Athena query history, SNS delivery records, immutable cost data).
- Mapping of that evidence to SOX, PCI DSS, GDPR, DORA, and BCBS 239 — skip the sections that don't apply to your account.
- Recommended runbooks for chargeback reproduction, anomaly response, and tag remediation escalation.

## What it costs to run

See [docs/COST_ESTIMATE.md](docs/COST_ESTIMATE.md) for a per-service breakdown across four account sizes (sandbox / small prod / mid-size / large enterprise). Headline numbers:

- **Framework baseline** (KMS, Secrets Manager, SNS, Lambdas, alarms, etc.): **~$7.50 / month** regardless of account size.
- **AWS Config** is the dominant variable — **~$80–$2 300 / month** depending on resources × churn.
- If Config is already enabled org-wide (typical with Control Tower), set `enable_config_recorder = false` and the framework's total drops to **~$30–$50 / month** even for large enterprise accounts.

## License

Internal — adapt for your institution's standards.

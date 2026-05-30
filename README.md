# Solidus FinOps

**Solidus FinOps** is a production-grade Terraform framework that provisions a
complete FinOps capability stack for AWS, aligned with the
[FinOps Foundation Capabilities](https://www.finops.org/framework/capabilities/).

It's built around one principle: every dollar must be traceable back to a
tag, a Cost Category, a budget owner, and an apply commit. Allocation
reproducibility, audit-defensible automation, and KMS-everywhere encryption
are the defaults. Defaults lean conservative (CMK encryption,
`prevent_destroy` on data, off-by-default destructive Lambdas) so the same
code is valid for SOX / PCI / GDPR / DORA workloads without modification.

This is **not** a thin wrapper around `aws_budgets_budget`. It is a
composition of seven modules that share patterns (events bus, DDB
STATE+ACTION audit log, per-Lambda DLQ + alarms, auto-rebuilt dashboards,
multi-region operational scan):

- **alerting** — events SNS bus + multi-channel dispatcher Lambda
  (Slack / Teams / PagerDuty / Opsgenie / email / generic webhooks / SQS),
  severity routing, dedup window, audit log.
- **cost-data-exports** — CUR 2.0 + FOCUS 1.0 via BCM Data Exports, S3 with
  KMS, Glue crawler, Athena workgroup, pre-built named-queries library,
  daily health-check Lambda (CUR freshness + crawler success + Athena
  probe), cross-account reader roles for Cloudability / 3rd-party tools.
- **tag-governance** — AWS Config rules for required tags (chunked over the
  6-tag managed-rule limit so nothing is silently dropped), tag-drift
  detection via EventBridge, weekly untagged-cost dollarization Lambda,
  allocation Resource Groups, tag taxonomy levels (mandatory / recommended
  / operational) as code.
- **budgets** — polymorphic budgets (account / service / tag / cost_category)
  with AWS Budget Actions (auto-enforcement on breach), daily performance
  Lambda (variance, burn-rate, adherence score), DDB trend store,
  metric-math burn-rate alarm, auto-provisioned dashboard.
- **idle-resource-cleanup** — six resource types (EBS, EIP, snapshot, NAT,
  ENI, LB), multi-region scanning, DDB-backed STATE + ACTION audit log,
  two-phase EBS deletion (snapshot-first), aging escalation, dry-run by
  default and off by default.
- **instance-scheduler** — tag-driven EC2 / RDS / RDS-cluster / ASG
  start/stop with **action-count blast-radius cap** (intentionally count-based,
  not dollar-denominated — see [its CHANGELOG](modules/instance-scheduler/CHANGELOG.md)
  for the rationale). DDB single-table audit + GSI for date-keyed action
  queries. Multi-region per-region failure isolation. Spot + transient-state
  handling. Auto-provisioned dashboard.
- **finops-metrics** — daily KPI aggregator (allocation %, RI/SP coverage
  and utilization, anomaly impact, forecast drift, spend-by-service),
  user-defined custom KPIs as Athena queries, DDB snapshot history driving
  7d / 30d moving averages + week-over-week drift alarms, auto per-tag-value
  dashboards, four sinks (CloudWatch + SSM + DDB + optional SNS).

Every module is **standalone-reusable** — no hard dependency on its
siblings. The root composition is the typical entry point, but each module
can also be consumed directly from a different Terraform workspace.

## Why this exists

Most "FinOps Terraform modules" you find online are toys: one budget, one
SNS topic, no audit trail, no encryption, no thought given to chargeback
reproducibility. Solidus FinOps was built with four assumptions:

1. **Someone will ask you, a year from now, to reproduce how cost was
   allocated to a specific team / business unit / product for a specific
   month.** Allocation logic therefore lives in code, in version control,
   with full git history. (Regulator, finance lead, internal audit — same
   need either way.)
2. **An account owner cannot tolerate an automation that deletes important
   data because someone forgot a tag.** Every destructive automation is off
   by default, dry-run when enabled, requires explicit per-resource-type
   opt-in, and respects exception tags.
3. **Encryption at rest is the right default.** Every S3 bucket uses KMS
   CMKs (not SSE-S3), every SNS topic is encrypted, every Lambda log group
   is encrypted, chat webhooks live in Secrets Manager rather than env
   vars.
4. **Silent failure is the worst failure.** Every Lambda has a DLQ + a
   CloudWatch error alarm + a DLQ-depth alarm routed to the events bus.

And one principle Solidus FinOps adopted after building the first version:

5. **Dollar-value reporting belongs in the analytics layer.** The framework
   emits action counts, KPI metrics, and DDB audit rows. Cloudability /
   CUR-backed dashboards / QuickSight / your BI tool of choice joins those
   to actual paid prices (including RIs, Savings Plans, EDP discounts).
   The framework deliberately _doesn't_ maintain a regional rate table —
   any hardcoded one is wrong on day one.

## Quality & compliance posture

As of v0.2.1, the framework passes every static-analysis gate with zero
unsuppressed findings:

| Check | Status |
|---|---|
| `terraform fmt -recursive` | ✅ Clean |
| `terraform validate` — root + every example | ✅ Clean |
| `tflint --recursive --format compact` | ✅ **0 issues** |
| **Checkov** (`bridgecrewio/checkov-action`, `soft_fail: false`) | ✅ **0 unsuppressed failures** |
| Python AST parse — every Lambda source | ✅ Clean |

Every Checkov rule the framework suppresses carries:

1. **An inline `# checkov:skip=<rule>:<reason>` comment** on the
   affected resource, with the rationale written out.
2. **A subsection in [docs/COMPLIANCE_NOTES.md](docs/COMPLIANCE_NOTES.md)**
   under "Documented Checkov suppressions" linking the rule, the
   resources, the why, the mitigation, and the relevant AWS docs.

Suppressions fall into three categories, all with documented rationale:

- **AWS-imposed limitations** — e.g. `ec2:StartInstances` doesn't accept
  resource-level permissions; the scope is enforced via tag-based
  filtering at the Lambda runtime instead.
- **Design decisions** — e.g. CloudTrail S3 data events at the org
  level replace per-bucket access logging; webhook URLs are immutable
  upstream so Secrets-Manager auto-rotation isn't applicable.
- **Static-analyser false positives** — e.g. Checkov 3.x sometimes
  fails to trace `aws_s3_bucket_*` companion resources (versioning,
  encryption, public-access-block, lifecycle) back to their parent
  bucket; the controls ARE configured in the linked resources.

The full audit-grade breakdown is in
[docs/COMPLIANCE_NOTES.md](docs/COMPLIANCE_NOTES.md).

## Repository layout

```
.
├── README.md                   # this file
├── CHANGELOG.md                # framework-level release notes (per-module CHANGELOGs in each module/)
├── LICENSE                     # Apache 2.0
├── NOTICE                      # required attribution per Apache 2.0
├── CONTRIBUTING.md             # how to contribute + conventions + CI expectations
├── CODE_OF_CONDUCT.md          # community standards
├── SECURITY.md                 # private vulnerability reporting flow
├── SUPPORT.md                  # where to get help (Discussions / Issues / docs)
│
├── versions.tf                 # required providers + Terraform version (root)
├── providers.tf                # AWS provider config (no credentials — TFE-managed)
├── variables.tf                # root input contract (strict <module>_<name> prefixing)
├── locals.tf                   # computed locals (tags, naming, effective_regions)
├── main.tf                     # module composition
├── outputs.tf                  # outputs surfaced to other workspaces
├── terraform.auto.tfvars.example
│
├── modules/
│   ├── alerting/                # events SNS bus + multi-channel dispatcher
│   ├── cost-data-exports/       # CUR 2.0 + FOCUS + Athena + health check
│   ├── tag-governance/          # Config rules + drift + untagged-cost + Resource Groups
│   ├── budgets/                 # polymorphic budgets + Budget Actions + performance Lambda
│   ├── idle-resource-cleanup/   # 6 resource-type detectors (off by default, dry-run first)
│   ├── instance-scheduler/      # tag-driven start/stop with action-count blast cap
│   └── finops-metrics/          # daily KPI aggregator + trends + custom KPIs
│
├── examples/
│   ├── minimal/                 # smallest viable deployment ("Crawl" phase)
│   ├── selective/               # pick-and-choose: only the modules you want
│   ├── production/              # full stack ("Run" phase)
│   └── cloudability-complement/ # framework provides execution + enforcement; Cloudability provides analytics
│
├── docs/
│   ├── ARCHITECTURE.md          # how the modules fit together
│   ├── COMPLIANCE_NOTES.md      # SOX / PCI / GDPR / DORA / BCBS 239 mapping
│   ├── COST_ESTIMATE.md         # per-service cost breakdown by account size
│   ├── GETTING_STARTED.md       # step-by-step first deployment
│   ├── PHASES.md                # Crawl / Walk / Run with enable-flag mappings
│   ├── TAG_GOVERNANCE_PATTERNS.md
│   └── TFE_SETUP.md             # Terraform Enterprise workspace config
│
├── diagrams/
│   ├── framework_structure.py  → framework-structure.png + .svg
│   ├── aws_architecture.py     → aws-architecture.png + .svg
│   └── requirements.txt
│
├── .github/
│   ├── CODEOWNERS               # review routing per path
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── ISSUE_TEMPLATE/          # bug_report.yml + feature_request.yml + config.yml
│   ├── dependabot.yml           # weekly TF provider + GHA + Python updates
│   └── workflows/
│       └── terraform-ci.yml     # fmt + validate + tflint + Python AST + (advisory) Checkov
│
├── .tflint.hcl                  # tflint configuration
├── .pre-commit-config.yaml      # local guardrails (terraform fmt / validate / tflint / Python syntax)
├── .editorconfig                # cross-editor formatting consistency
└── .gitignore
```

## Community & governance

Solidus FinOps follows the conventions a serious open-source project is
expected to follow:

- **[CONTRIBUTING.md](CONTRIBUTING.md)** — how to contribute, dev setup,
  naming convention, CI checks, release process.
- **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** — community standards.
- **[SECURITY.md](SECURITY.md)** — private vulnerability reporting flow.
  Use GitHub Security Advisories or encrypted email; do not open public
  issues for security bugs.
- **[SUPPORT.md](SUPPORT.md)** — where to ask questions, file bugs,
  propose features, and what response times to expect.
- **[LICENSE](LICENSE)** + **[NOTICE](NOTICE)** — Apache 2.0.
- **[.github/CODEOWNERS](.github/CODEOWNERS)** — review routing.
- **[.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md)**
  + structured issue forms — first-contribution friction reduced to a
  checklist.
- **[.github/dependabot.yml](.github/dependabot.yml)** — weekly Terraform
  + GitHub Actions + Python dependency updates (major AWS-provider bumps
  are review-only, never auto-merged).
- **[.pre-commit-config.yaml](.pre-commit-config.yaml)** — local hooks
  that catch what CI catches (`terraform fmt`, `validate`, `tflint`,
  Python AST parse, plus a guard against re-introducing legacy variable
  names).
- **[.editorconfig](.editorconfig)** — formatter consistency across editors.

## Quick start

1. Copy `terraform.auto.tfvars.example` to `terraform.auto.tfvars` and fill
   in your values (`namespace`, `environment`, `aws_primary_region`, etc.).
2. In your TFE workspace, set the following sensitive variables:
   - `alerting_slack_webhook_url` (if using Slack alerting)
   - `alerting_teams_webhook_url` (if using Teams alerting)
3. Run `terraform plan` and review.
4. `terraform apply`.

See [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) for the full
walk-through, including IAM bootstrap requirements for the TFE workspace's
AWS credentials.

### Variable naming convention

Solidus FinOps uses a strict `<module>_<name>` prefix on every submodule
variable. Booleans use the suffix form `<module>_enabled` (not
`enable_<module>`). Only truly cross-cutting concerns (`namespace`,
`environment`, `stack_name`, `aws_primary_region`, `aws_secondary_regions`,
`create_kms_key`, `log_retention_days`, `lambda_runtime`) are un-prefixed.

```hcl
module "finops" {
  source = "./..."

  namespace             = "examplecorp"
  environment           = "shared"
  aws_primary_region    = "eu-central-1"
  aws_secondary_regions = ["us-east-1", "ap-southeast-1"]

  cost_data_exports_enabled        = true
  cost_data_exports_focus_enabled  = true
  cost_data_exports_athena_enabled = true

  tag_governance_enabled       = true
  tag_governance_required_tags = [...]

  instance_scheduler_enabled              = true
  instance_scheduler_max_actions_per_tick = 200

  finops_metrics_enabled                  = true
  finops_metrics_tag_value_dashboard_tag  = "BusinessUnit"
  finops_metrics_custom_kpis              = { ... }

  alerting_slack_webhook_url = var.slack_webhook_url
}
```

### Multi-region operational scan

`aws_primary_region` is the home for framework infrastructure (KMS, DDB,
Lambdas, dashboards, events bus). `aws_secondary_regions` (default `[]`)
extends the **scanning reach** of `idle-resource-cleanup` and
`instance-scheduler` — the framework computes
`local.effective_regions = [primary] + secondaries` and uses it as the
default for every per-module `*_scan_regions` left empty. Per-module
overrides still win when set. See the
[multi-region audit notes](CHANGELOG.md) in the framework changelog for what
each module does (and does not) iterate across regions.

## Diagrams

Architecture diagrams live under [diagrams/](diagrams/), generated with the
Python [`diagrams`](https://diagrams.mingrammer.com/) library (Graphviz,
real AWS icons). Source is Python, outputs are PNG + SVG, all committed:

- [diagrams/framework_structure.py](diagrams/framework_structure.py) →
  [framework-structure.png](diagrams/framework-structure.png) /
  [.svg](diagrams/framework-structure.svg) — modules grouped by FinOps
  Foundation Capability domain, with the events-bus flow
- [diagrams/aws_architecture.py](diagrams/aws_architecture.py) →
  [aws-architecture.png](diagrams/aws-architecture.png) /
  [.svg](diagrams/aws-architecture.svg) — AWS services and how they connect

Render locally:

```bash
pip install -r diagrams/requirements.txt   # plus graphviz at the OS level
cd diagrams && python framework_structure.py && python aws_architecture.py
```

## Deployment phases

The framework is designed to be adopted in stages — see
[docs/PHASES.md](docs/PHASES.md) for the FinOps Foundation Crawl / Walk /
Run model mapped to concrete enable-flags, plus the exit criteria for each
phase.

| Example                                                               | What's on                                                                                   | When to use                                                |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| [examples/minimal](examples/minimal/)                                 | Cost data, Athena, one account budget, email-only alerts                                    | "Crawl" phase — first deployment                           |
| [examples/selective](examples/selective/)                             | **Budgets + idle-resource-cleanup + tag-governance** only, every other module ready-to-flip | When you want to pick exactly which capabilities to deploy |
| [examples/production](examples/production/)                           | Full stack: every module on, multi-region scanning, regulatory log retention, Slack + Teams | "Run" phase — mature deployment                            |
| [examples/cloudability-complement](examples/cloudability-complement/) | Framework provides execution + enforcement + audit; Cloudability provides analytics         | When you already run Apptio Cloudability                   |

## What's evolved vs. typical FinOps Terraform

If you already have a FinOps Terraform setup, here is where Solidus FinOps
typically goes further:

| Area                  | Typical setup                                        | Solidus FinOps                                                                                                                                                     |
| --------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Cost data export      | CUR v1                                               | CUR 2.0 **plus** FOCUS 1.0, side-by-side                                                                                                                           |
| S3 encryption         | SSE-S3                                               | KMS CMK with key policy for least-privilege access, `prevent_destroy` lifecycle                                                                                    |
| S3 lifecycle          | Deep-Archive everything → Athena breaks              | Current versions to Glacier Instant Retrieval (still Athena-queryable); noncurrent to Deep Archive                                                                 |
| Idle resource cleanup | "Delete after 30 days" Lambda                        | Dry-run by default, off by default, tag-based opt-in, exception-tag honored, DDB STATE+ACTION audit log                                                            |
| Instance scheduler    | Opt-out (everything stops unless tagged)             | Opt-in (nothing stops unless tagged `Schedule=...`), off by default, **count-based blast cap** (no false dollar estimates)                                         |
| Tag remediation       | Auto-tag with "untagged"                             | Flag and notify; never silently mutate someone's resource                                                                                                          |
| Tag-rule limits       | Silently drop tags past the 6-key managed-rule limit | Chunked into N rules of 6, no silent truncation                                                                                                                    |
| Budget inputs         | Hard-shaped variables per scope                      | One polymorphic `budgets_items` map (account / service / tag / cost_category)                                                                                      |
| Budget alerts         | Email to one inbox                                   | Events SNS topic, fanned out by a multi-channel dispatcher (Slack / Teams / PagerDuty / Opsgenie / email / webhooks / SQS) with severity routing, dedup, audit log |
| Chat webhooks         | Plaintext env var                                    | Stored in Secrets Manager (CMK-encrypted), fetched at runtime, cached per warm container                                                                           |
| Lambda failure mode   | Silent                                               | Per-Lambda DLQ + CloudWatch error and DLQ-depth alarms routed to the events bus                                                                                    |
| Audit                 | None                                                 | DDB STATE+ACTION audit rows on every action; CMK-encrypted log retention up to 7y                                                                                  |
| Trend metrics         | "Compare to last month manually"                     | Daily KPI snapshots in DDB → 7d / 30d moving averages + week-over-week drift alarms computed automatically                                                         |
| Custom KPIs           | Not supported                                        | User-defined Athena queries become first-class KPIs with metrics, DDB snapshots, optional alarms, and dashboard widgets                                            |
| Multi-region          | One region only                                      | `aws_primary_region` + `aws_secondary_regions`; framework scans all configured regions with per-region failure isolation                                           |
| Dollar reporting      | Hardcoded rate table that lies                       | Deferred to the analytics layer (Cloudability / CUR-backed BI). The framework emits provenance; pricing joins happen where prices actually live.                   |

## Requirements

- Terraform >= 1.6
- AWS provider >= 5.50 (for FOCUS data exports + BCM Data Exports v2)
- `archive` provider >= 2.4
- AWS account with permissions listed in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)
- (Optional, for full feature set) AWS Business or Enterprise Support plan —
  required for Trusted Advisor full checks and Compute Optimizer enhanced
  infrastructure metrics.

## Audit & compliance evidence

Read [docs/COMPLIANCE_NOTES.md](docs/COMPLIANCE_NOTES.md) for:

- What evidence the framework produces (CloudTrail-ready actions, Athena
  query history, SNS delivery records, immutable cost data, DDB audit
  rows).
- Mapping of that evidence to SOX, PCI DSS, GDPR, DORA, and BCBS 239 — skip
  the sections that don't apply to your account.
- Recommended runbooks for chargeback reproduction, anomaly response, and
  tag remediation escalation.

## What it costs to run

See [docs/COST_ESTIMATE.md](docs/COST_ESTIMATE.md) for a per-service
breakdown across four account sizes (sandbox / small prod / mid-size /
large enterprise). Headline numbers:

- **Framework baseline** (KMS, Secrets Manager, SNS, Lambdas, DDB tables,
  alarms): **~$8 / month** regardless of account size.
- **AWS Config** is the dominant variable — **~$80–$2 300 / month**
  depending on resources × churn.
- If Config is already enabled org-wide (typical with Control Tower), set
  `tag_governance_record_global_resources = false` and the total drops
  significantly even for large enterprise accounts.

## About the name

_Solidus_ (Latin for _solid_) was the gold coin minted across the late
Roman and Byzantine empires from the 4th to the 11th century — famous for
its remarkable consistency in weight and purity over hundreds of years.
Each coin carried a **mint mark** identifying where and when it was struck,
so auditors could trace any coin back to its origin.

The metaphor maps directly onto what this framework does: every cost line
should be traceable back to a tag, a Cost Category rule, a budget owner,
and an apply commit — and the audit trail should outlast the people who
built it.

## License

Licensed under the **Apache License, Version 2.0** — see [LICENSE](LICENSE)
and [NOTICE](NOTICE).

Apache 2.0 gives you explicit patent grant, easy commercial reuse, and the
standard `NOTICE`-file attribution convention. If your organisation needs
a different license for internal redistribution, the Apache 2.0 grant
includes the right to relicense your modifications — see clause 4 of the
license text.

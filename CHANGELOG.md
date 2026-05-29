# Changelog

All notable changes to the FinOps framework are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [SemVer](https://semver.org/spec/v2.0.0.html). Pre-1.0 releases:
breaking changes can land in any minor version, so pin the module ref explicitly.

Per-module changelogs live alongside each module:
- [modules/instance-scheduler/CHANGELOG.md](modules/instance-scheduler/CHANGELOG.md)
- [modules/finops-metrics/CHANGELOG.md](modules/finops-metrics/CHANGELOG.md)

## [Unreleased]

## [0.1.0] — 2026-05-29

Initial tagged release. The framework is functional end-to-end, every example
deployment plans cleanly, and the module surface is structured for forward
extension. Calling this 0.1.0 (not 1.0.0) signals that the variable contract
and outputs may still shift before a stable release.

### Modules included

- **alerting** — multi-channel events bus + dispatcher Lambda (Slack / Teams /
  PagerDuty / Opsgenie / email / webhooks / SQS). Severity routing, dedup,
  audit log. Standalone-reusable.
- **cost-data-exports** — CUR 2.0 + FOCUS 1.0 via BCM Data Exports, S3 with
  KMS, Glue crawler, Athena workgroup, pre-built Athena named-queries library,
  daily health-check Lambda (CUR freshness + crawler success + query probe),
  cross-account reader roles for Cloudability / 3rd-party tools.
- **tag-governance** — Config rules for required tags (chunked across the
  6-tag managed-rule limit), tag-drift detection via EventBridge, tag
  taxonomy as code, weekly untagged-cost dollarization Lambda, allocation
  Resource Groups, mandatory/recommended/operational tag levels.
- **budgets** — polymorphic budgets (account / service / tag / cost_category),
  AWS Budget Actions (auto-enforcement on breach), daily performance Lambda
  (variance, burn-rate, adherence score), DDB trend store, auto-provisioned
  CloudWatch dashboard.
- **idle-resource-cleanup** — six resource types (EBS, EIP, snapshot, NAT,
  ENI, LB), multi-region scanning, DDB-backed STATE + ACTION audit log,
  two-phase EBS deletion (snapshot-first), aging escalation, dry-run default.
- **instance-scheduler** — tag-driven EC2 / RDS / RDS-cluster / ASG start/stop
  with action-count blast-radius cap (replaces dollar-denominated ceiling that
  was wrong on day one). DDB single-table audit + GSI for date-keyed action
  queries. Multi-region per-region failure isolation. Spot + transient-state
  handling. Standalone-reusable. Auto-provisioned dashboard. See
  [its CHANGELOG](modules/instance-scheduler/CHANGELOG.md) for details.
- **finops-metrics** — daily KPI aggregator (allocation %, commitment
  coverage/utilization, anomaly impact, forecast drift, spend by service),
  user-defined custom KPIs as Athena queries, DDB snapshot history (drives
  7d / 30d moving averages + week-over-week drift alarms), auto per-tag-value
  dashboards, four sinks (CloudWatch + SSM + DDB + optional SNS).
  Standalone-reusable. See [its CHANGELOG](modules/finops-metrics/CHANGELOG.md)
  for details.

### Root framework

- **Strict variable naming convention.** Every submodule variable is prefixed
  with its module slug (`cost_data_exports_*`, `tag_governance_*`,
  `instance_scheduler_*`, `idle_cleanup_*`, `finops_metrics_*`,
  `budgets_*`, `alerting_*`). Booleans use the suffix form
  `<module>_enabled` (not `enable_<module>`). Only truly cross-cutting
  concerns (namespace, environment, KMS, log retention, Lambda runtime,
  region) are un-prefixed.
- **Multi-region operational scan.** New `aws_primary_region` (home for
  framework infra) + `aws_secondary_regions` (additional reach for scanning
  modules). Computed `local.effective_regions = [primary] + secondaries` is
  the default for any per-module `*_scan_regions` left empty. Per-module
  scan_regions still wins when set.
- **`enabled_modules` + `framework_status` outputs** — single-glance summary
  of which modules are on, region reach, KMS key, events bus, and every
  dashboard URL keyed by module.
- **Standalone-mode for the heaviest modules.** Both `instance-scheduler` and
  `finops-metrics` accept `events_topic_arn = null` cleanly; their metrics,
  DDB audit, and dashboards continue to function without an events bus.

### Examples

- **examples/minimal** — Crawl-phase deployment. CUR + Athena + one account
  budget + email notifications. No tagging, no automation.
- **examples/selective** — pick-and-choose deployment. budgets +
  idle-resource-cleanup + tag-governance enabled; rest off.
- **examples/production** — full Run-phase stack. Every capability on,
  multi-region scanning, regulatory log retention (7y), Slack + Teams + email.
- **examples/cloudability-complement** — for organizations on Apptio
  Cloudability. Framework provides execution + enforcement + audit;
  Cloudability provides analytics.

### Diagrams

- **diagrams/aws_architecture.py** — full AWS-icon architecture diagram.
  Renders PNG + SVG via the [diagrams](https://diagrams.mingrammer.com/)
  Python library.
- **diagrams/framework_structure.py** — FinOps-Foundation-aligned module
  structure diagram, grouped by Capability domain.

### Documentation

- [README.md](README.md) — framework overview
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/COMPLIANCE_NOTES.md](docs/COMPLIANCE_NOTES.md)
- [docs/COST_ESTIMATE.md](docs/COST_ESTIMATE.md)
- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)
- [docs/PHASES.md](docs/PHASES.md)
- [docs/TAG_GOVERNANCE_PATTERNS.md](docs/TAG_GOVERNANCE_PATTERNS.md)
- [docs/TFE_SETUP.md](docs/TFE_SETUP.md)
- Per-module README + (where applicable) `docs/EDGE_CASES.md`

### Design principles

- **Reproducible allocation.** Cost categorisation logic lives in HCL with
  full git history. A year from now, "how was cost allocated for August?"
  is answerable from `git show`.
- **Off-by-default destruction.** Mutation-capable Lambdas
  (idle-resource-cleanup, instance-scheduler) are opt-in. Dry-run is the
  default first state. Exception tags are respected.
- **Encryption everywhere at rest.** KMS CMKs for S3, SNS, DDB, Secrets
  Manager, CloudWatch log groups. Webhooks live in Secrets Manager.
- **No silent failure.** Every Lambda has a DLQ + a CloudWatch error alarm +
  a DLQ-depth alarm wired to the events bus.
- **Dollar-value reporting belongs in the analytics layer.** The framework
  emits action counts and DDB audit rows; Cloudability / CUR-backed
  dashboards join those to actual paid prices (RIs / SPs / EDP).

### Roadmap notes

Not in 0.1.0 but anticipated for future minor versions:
- Cross-account aggregation in `finops-metrics`
- Step Functions sharding for very large multi-region scans
- Pre-built `examples/standalone/` packs for each module
- terratest / `terraform test` test suites
- Migration of DDB `hash_key`/`range_key` to the v6-provider `key_schema` form
  once the syntax stabilises (currently kept on the deprecated form per the
  comments in `dynamodb.tf` files)

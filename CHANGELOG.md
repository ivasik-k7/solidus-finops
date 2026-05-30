# Changelog — Solidus FinOps

All notable changes to the Solidus FinOps framework are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [SemVer](https://semver.org/spec/v2.0.0.html). Pre-1.0 releases:
breaking changes can land in any minor version, so pin the module ref explicitly.

Per-module changelogs live alongside each module:
- [modules/instance-scheduler/CHANGELOG.md](modules/instance-scheduler/CHANGELOG.md)
- [modules/finops-metrics/CHANGELOG.md](modules/finops-metrics/CHANGELOG.md)

## [Unreleased]

## [0.2.1] — 2026-05-30

The "Solidus" release. The framework gets a name, a license, a complete
set of open-source governance files, a clean static-analysis pass, and
one legitimately new feature (the budgets burn-rate metric-math alarm
that had been declared but never built).

### Added

- **Framework name: Solidus FinOps.** Named after the late-Roman gold coin
  whose mint mark let auditors trace every coin back to its origin —
  matching the framework's design goal of full provenance for every dollar
  of cloud spend. README has the full "About the name" rationale.
- **LICENSE** (Apache 2.0) + **NOTICE** at the repo root. Apache 2.0 chosen
  for the explicit patent grant + the standard NOTICE attribution
  convention auditors expect. Copyright 2026 Ivan Kovtun. Clause 4 lets
  consuming organisations relicense internal modifications without
  re-asking.
- **Burn-rate breach alarm in `budgets` module.** The
  `burn_rate_alarm_days_to_breach` variable had been declared since v0.1.0
  but never wired to a CloudWatch resource. v0.2.1 adds the missing
  `aws_cloudwatch_metric_alarm.burn_rate_low` — a metric-math alarm that
  fires when ANY budget's `BurnRateDaysToBreach` drops below the threshold.
  Uses `dynamic "metric_query"` blocks over `keys(var.budgets)` with
  `m0..mN` IDs so CloudWatch ID constraints are met regardless of budget
  key characters.
- **`versions.tf` on every module + example.** Five older modules
  (`alerting`, `budgets`, `cost-data-exports`, `idle-resource-cleanup`,
  `tag-governance`) and all four `examples/*` now carry an explicit
  `terraform { required_version + required_providers }` block. Lower
  bounds only (`aws >= 5.50.0`, `archive >= 2.4.0`) — no upper bounds in
  any reusable module.
- **Open-source governance files** at the repo root + under `.github/`:
  - `CONTRIBUTING.md` — full contributor flow: how to branch, the strict
    `<module>_<name>` naming convention, architectural invariants
    (encryption everywhere, off-by-default destruction, DDB STATE+ACTION
    audit, no hardcoded rate tables, standalone-reusable modules), CI
    expectations, release process.
  - `CODE_OF_CONDUCT.md` — FinOps-context-aware standards (engage in
    good faith, critique code not people, acknowledge tradeoffs,
    respect domain expertise). Reporting to maintainer; warning →
    cool-off → permanent-ban enforcement ladder.
  - `SECURITY.md` — vulnerability reporting via GitHub Security
    Advisories (preferred) or encrypted email. 48h ack, 7d triage,
    30–90d disclosure window. Lists out-of-scope items (IAM `*` for
    EC2/RDS/ASG — AWS limitation, not a vulnerability).
  - `SUPPORT.md` — channel routing (Discussions for questions, Issues
    for bugs, Security Advisories for vulnerabilities). Includes a
    "what to include in a bug report" checklist + incident-recovery
    knobs for production fires.
  - `.github/CODEOWNERS` — review routing per path. Root composition,
    security-sensitive paths (IAM, KMS, LICENSE), per-module ownership
    all mapped.
  - `.github/PULL_REQUEST_TEMPLATE.md` — checklist mirroring the
    CONTRIBUTING.md conventions + the architectural invariants. Forces
    a deliberate answer on breaking changes + security review.
  - `.github/ISSUE_TEMPLATE/bug_report.yml` + `feature_request.yml` +
    `config.yml` — structured forms with the affected-module dropdown,
    required version info, security-issue redirect to SECURITY.md,
    blank-issue disabled.
  - `.github/dependabot.yml` — weekly TF provider + GitHub Actions
    updates per-module (so PRs are narrowly scoped), monthly Python
    diagram-dependency updates. Major AWS-provider bumps are
    deliberately NOT auto-grouped — they get standalone PRs for review.
  - `.editorconfig` — cross-editor consistency: 2-space TF / YAML,
    4-space Python (PEP 8), LF endings, UTF-8, final newline.
    Markdown trailing-whitespace preserved (significant for hard line
    breaks).
  - `.pre-commit-config.yaml` — local guardrails that run the same
    checks CI runs (`terraform fmt`, `validate`, `tflint`, Python AST
    parse) plus two custom hooks: one that fails the commit if a
    `modules/*` source file changes without an entry to its
    `CHANGELOG.md`, and one that blocks re-introducing the pre-v0.1.0
    variable names (`enable_anomaly_detection`, `cost_categories`,
    `notification_emails`, etc.).

### Changed

- **All root + framework documentation reworked** to reflect the Solidus
  FinOps name, the current 7-module composition (no more deleted-module
  references), and the strict `<module>_<name>` variable naming
  convention introduced in v0.1.0:
  - `README.md` — full rewrite (gold-coin metaphor, current modules,
    naming convention + multi-region sections, "About the name" footer)
  - `docs/ARCHITECTURE.md` — full rewrite (updated capability-domain
    table, redrawn data-flow ASCII with the dispatcher + DDB audit
    pattern, new "Audit pattern" section, expanded failure-modes table)
  - `docs/PHASES.md` — full rewrite (Crawl / Walk / Run mappings use new
    variable names + new flags from v0.1.0 added to the right phase)
  - `docs/COMPLIANCE_NOTES.md` — full rewrite (auditor scenarios use the
    DDB STATE+ACTION audit pattern, control mappings updated)
  - `docs/GETTING_STARTED.md` — full rewrite (new variable names,
    expanded IAM permission list, 13-Lambda inventory, dashboard-drift
    note, updated Crawl→Run progression)
  - `docs/COST_ESTIMATE.md` — baseline now ~$11/mo (was $7.50/mo),
    Lambda inventory updated to 13 functions, DynamoDB cost section
    added, variance-knob list expanded with new finops-metrics knobs
  - `docs/TFE_SETUP.md` — workspace + IAM role names, variable table
    uses new prefixed names, run-policy recommendations expanded with
    `idle_cleanup_dry_run` + `instance_scheduler_max_actions_per_tick`
    approval gates
  - `docs/TAG_GOVERNANCE_PATTERNS.md` — variable renames only
  - Framework `CHANGELOG.md` title rebranded to `Changelog — Solidus FinOps`
- **Restructured `aws_secretsmanager_secret*` `for_each` blocks** in the
  `alerting` module to iterate `nonsensitive(toset(keys(...)))` instead
  of the sensitive-marked map directly. URLs stay sensitive in plan
  output; tflint's static evaluator stops choking on the iteration. 12
  resources affected (slack/teams/pagerduty/opsgenie/webhook × 2 each).

### Fixed

- **tflint runtime blocker** at `modules/alerting/main.tf:418` — the
  `aws_dynamodb_table_invalid_stream_view_type` rule was misfiring on
  `for_each` over `cty.EmptyObjectVal.Mark(marks.Sensitive)`. Fixed by
  the `nonsensitive(toset(keys(...)))` restructure above.
- **26 tflint warnings**:
  - Missing `terraform_required_version` on 5 module main.tf files + 4
    example main.tf files (fixed by adding `versions.tf` to each)
  - Missing version constraints in `required_providers` for the `aws`
    and `archive` providers on the 5 older modules (same fix)
  - Unused `data "aws_caller_identity" "current"` in
    `cost-data-exports`, `idle-resource-cleanup`, and `instance-scheduler`
    (removed)
  - Unused `data "aws_partition" "current"` in `cost-data-exports`
    (removed)
  - Unused `data "aws_region" "current"` in `alerting` (removed)
  - Unused `local.builtin_scalar_kpi_metrics` in `finops-metrics`
    (removed)
  - Unused `var.burn_rate_alarm_days_to_breach` in `budgets` — the
    declared-but-never-implemented variable is now backed by the new
    burn-rate alarm (see Added)

### Verification

- `terraform fmt -recursive` clean
- `terraform validate` green on root + all 4 examples
  (only the persistent DDB `hash_key`/`range_key` deprecation warnings
  in `idle-resource-cleanup` remain — that's an AWS-provider migration
  deferred per [modules/idle-resource-cleanup/main.tf](modules/idle-resource-cleanup/main.tf) comments)
- Python syntax check passes on all 16 Lambda files
- Zero `var.<old_name>` references in any `.tf`, `.tfvars`, or `.md` file

### Migration from v0.1.0

No breaking changes. The variable surface is identical. Update consumers
by:

1. `git pull` the new tag
2. `terraform init` (picks up the new `versions.tf` files)
3. `terraform plan` will show:
   - One new alarm (`aws_cloudwatch_metric_alarm.burn_rate_low`) inside
     the `budgets` module, only if you have ≥ 1 budget AND
     `budgets_performance_tracking_enabled = true` AND
     `budgets_burn_rate_alarm_days_to_breach != null` (default 7).
     Disable by setting `budgets_burn_rate_alarm_days_to_breach = null`.
   - Minor in-place updates to the `aws_secretsmanager_secret*` resources
     if any are present — the `nonsensitive(toset(keys(...)))`
     restructure doesn't change resource identity, only the iteration
     expression in the plan diff.

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

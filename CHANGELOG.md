# Changelog — Solidus FinOps

All notable changes to the Solidus FinOps framework are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [SemVer](https://semver.org/spec/v2.0.0.html). Pre-1.0 releases:
breaking changes can land in any minor version, so pin the module ref explicitly.

Per-module changelogs live alongside each module:
- [modules/instance-scheduler/CHANGELOG.md](modules/instance-scheduler/CHANGELOG.md)
- [modules/finops-metrics/CHANGELOG.md](modules/finops-metrics/CHANGELOG.md)

## [Unreleased]

## [0.3.0] — 2026-05-31

The "structure & evidence" release. Five remaining modules pick up the
multi-file structure that `instance-scheduler` and `finops-metrics`
already had, four new formal documents land for stakeholder review, the
cost estimate is rewritten to honestly reflect the CloudWatch
custom-metric + dashboard surface that v0.2.1 introduced but didn't
budget for, and the CI/CD surface goes from one workflow to eight.

No functional Terraform changes — every input variable, output, and
resource ID is unchanged from v0.2.1. Consumers do not need to update
their root composition.

**Static-analysis status as of this tag:**

- `terraform fmt -recursive` — clean
- `terraform validate` — green on root + all 4 examples
- `tflint --recursive` — zero issues
- `checkov` with `soft_fail: false` — zero unsuppressed failures
- Every new `.github/workflows/*.yml` parses as valid YAML
- Every new doc cross-references the others without broken links

### Added

#### Module file structure (5 of 5 remaining modules split)

`instance-scheduler` and `finops-metrics` already used the
multi-file convention; v0.3.0 extends it to every other module. Each
ex-monolith `main.tf` becomes a header-only file pointing to a split
across the standard files (`versions.tf`, `variables.tf`,
`outputs.tf`, `locals.tf`, `data.tf`, `iam.tf`, `lambda.tf`,
`eventbridge.tf`, `cloudwatch.tf`, `sqs.tf`, `dynamodb.tf`) plus
module-specific files.

| Module | Pre-split main.tf | Post-split file count | Module-specific files |
|---|---|---|---|
| `alerting` | 829 lines | 13 .tf files | `sns.tf`, `secrets.tf` |
| `tag-governance` | 845 lines | 14 .tf files | `s3.tf`, `config.tf`, `resourcegroups.tf` |
| `budgets` | 893 lines | 13 .tf files | `budgets.tf` |
| `idle-resource-cleanup` | 904 lines | 12 .tf files | — |
| `cost-data-exports` | 1383 lines | 15 .tf files | `s3.tf`, `bcm.tf`, `glue.tf`, `athena.tf` |

Every module's `main.tf` is now a documentation header (20–45 lines)
explaining the file layout — same shape `instance-scheduler` and
`finops-metrics` established. Every Checkov suppression comment,
X-Ray + reserved-concurrency wiring, and `lifecycle { prevent_destroy
= true }` is preserved across the split.

#### Formal stakeholder documentation

Four new documents under `docs/` target distinct reviewer audiences,
each substantive enough to stand on its own:

- **[docs/EXECUTIVE_BRIEF.md](docs/EXECUTIVE_BRIEF.md)** (~220 lines) —
  CFO / FinOps lead / exec sponsor. What the framework is, what it
  costs, what it saves, what it explicitly will NOT do. Designed for
  pre-read packs.
- **[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)** (~250 lines) —
  Security review board / appsec / audit. Full STRIDE analysis
  (Spoofing / Tampering / Repudiation / Information disclosure / DoS /
  Elevation of privilege), trust-boundary diagram, defense-in-depth
  layers, accepted-risks register, validation checklist.
- **[docs/DISASTER_RECOVERY.md](docs/DISASTER_RECOVERY.md)** (~425 lines) —
  SRE / oncall / risk. Per-module RPO / RTO matrix, per-disaster-class
  playbooks (region outage, DDB corruption, S3 corruption, KMS loss,
  module failure, audit tampering), quarterly tabletop schedule.
- **[docs/OPERATIONAL_RUNBOOK.md](docs/OPERATIONAL_RUNBOOK.md)** (~525 lines) —
  SRE / FinOps oncall. The 5 most common alarms with diagnostic
  commands, snooze / rotate-webhook / replay-DLQ / pause-via-reserved-
  concurrency procedures, quarterly health checks, severity matrix.
- **[docs/METRICS_GLOSSARY.md](docs/METRICS_GLOSSARY.md)** (~365 lines) —
  Analytics consumers / dashboard authors / alarm tuners. Every metric
  across the 7 framework namespaces with exact unit, dimensions,
  emission cadence, built-in alarms, SSM mirror paths. DDB row-shape
  reference. CloudWatch cardinality cost-driver checklist.

Combined: the `docs/` footprint grows from ~3 400 lines to ~5 160
lines. An evaluator opening any of the new documents finds links into
every adjacent one.

#### CI/CD surface: 1 workflow → 8 workflows

Pre-v0.3.0 the framework had one CI workflow (`terraform-ci.yml`:
fmt + tflint + checkov). v0.3.0 adds seven more and enhances the
existing one:

- **[`terraform-ci.yml`](.github/workflows/terraform-ci.yml)** *(enhanced)* —
  adds `validate` matrix across root + all 4 examples (`fail-fast:
  false`), provider-plugin cache keyed on every `.terraform.lock.hcl`,
  `concurrency` group with `cancel-in-progress: true`, and a
  `summary` job that posts a markdown pass/fail table to the GitHub
  Actions job summary.
- **[`python-ci.yml`](.github/workflows/python-ci.yml)** *(new)* —
  ruff `check` + ruff `format --check` + `python -m compileall` +
  advisory mypy with `boto3-stubs[essential]`. Matrix over Python
  3.11 + 3.12 (forward-compat). `paths:` filter
  `modules/**/*.py`.
- **[`security.yml`](.github/workflows/security.yml)** *(new)* —
  three jobs: Trivy filesystem scan (severity CRITICAL+HIGH, SARIF →
  code scanning); Gitleaks for committed secrets; CodeQL on the
  Python Lambda code. Triggers: PR + push to main + weekly cron
  (Monday 09:00 UTC).
- **[`release.yml`](.github/workflows/release.yml)** *(new)* —
  tag-push (`v*.*.*`) triggered. Validates semver, extracts the
  matching `## [X.Y.Z]` section from `CHANGELOG.md` as release body,
  creates GH release via `softprops/action-gh-release@v2`, attaches
  the rendered diagrams (PNG + SVG) as release assets, sniffs
  `alpha/beta/rc` → marks prerelease.
- **[`docs-quality.yml`](.github/workflows/docs-quality.yml)** *(new)* —
  three jobs: Lychee link-checker with cached link database;
  markdownlint-cli2 with framework-specific relaxed config;
  `module-docs-presence` bash check that every module has
  `README.md` + `CHANGELOG.md` + `docs/EDGE_CASES.md`.
- **[`scorecard.yml`](.github/workflows/scorecard.yml)** *(new)* —
  OpenSSF Scorecard weekly + on push to main + manual dispatch.
  SARIF upload to GH code scanning + opt-in publish to
  scorecard.dev for the supply-chain credibility signal.
- **[`dependency-review.yml`](.github/workflows/dependency-review.yml)** *(new)* —
  GitHub `dependency-review-action@v4` on every PR.
  `fail-on-severity: high` blocks merge on HIGH+ CVE in new deps;
  license allowlist (MIT / Apache-2.0 / BSD-2 / BSD-3 / ISC /
  MPL-2.0 / 0BSD). PR comment summary always.
- **[`drift-check.yml`](.github/workflows/drift-check.yml)** *(new)* —
  Monday 06:00 UTC + manual. Scheduled syntax/validate sweep across
  root + 4 examples. On failure, opens (or comments on existing)
  GitHub issue tagged `drift` / `ci` with the failing matrix-path
  and a run link. De-dupes against existing open `drift`-labeled
  issues so it can't spam.

Every new workflow enforces the same hygiene baseline: actions pinned
to a specific major version, top-level `permissions:` block scoped to
minimum, `concurrency:` group with `cancel-in-progress: true` on PR
triggers, `paths:` filter to skip irrelevant changes, `timeout-minutes:`
on every job, `set -euo pipefail` in every multi-line `run:` block.

### Changed

- **[docs/COST_ESTIMATE.md](docs/COST_ESTIMATE.md) rewritten** with
  two material line items that v0.2.1 was emitting but not budgeting
  for:
  - **CloudWatch custom metrics** — the framework emits ~70 distinct
    metrics across 7 namespaces at $0.30/metric/mo = **~$21/mo**
    previously hidden.
  - **CloudWatch dashboards** — 5 auto-provisioned dashboards, first 3
    free + $3/mo each thereafter = **~$6/mo** previously hidden.

  Net impact on the framework baseline: **~$11 → ~$39 / mo**. The cost
  was always being spent; the document was wrong to omit it.

  Other rewrites:
  - X-Ray Active tracing line item added (~$0.10/mo at framework
    volume — effectively free, but it's accounted now).
  - New multi-region scenario added to §5 (primary + 1 secondary
    region; +~$3/mo from additional `Region` dimension on scheduler +
    idle metrics).
  - Lambda count corrected to 13 (was "~10" pre-v0.2.1).
  - Cost-variance ranking (§6) reordered:
    `finops_metrics_tag_value_dashboard_tag` is now ranked #4 — a
    high-cardinality choice (Owner / AccountId) can push it from $3/mo
    to $150/mo. The hidden lever surfaced.
  - As-of date: 2026-05-31. Every numeric claim re-verified against
    current AWS public list pricing.
- **All Checkov suppression comments preserved across the module
  splits** — every `# checkov:skip=<rule>:<reason>` in the pre-split
  monolith is in the same logical position in the split file, with
  identical reasoning. `docs/COMPLIANCE_NOTES.md` references still
  resolve.

### Fixed

- **CloudWatch custom-metric + dashboard costs are now accounted for
  in `docs/COST_ESTIMATE.md`.** Not a bug in the framework; a gap in
  the documentation. (See "Changed" above.)
- **Validate matrix in `terraform-ci.yml` is no longer commented out.**
  The original `terraform-ci.yml` shipped with the `validate` job
  commented out as a "TODO". v0.3.0 enables it across root + 4
  examples with `fail-fast: false`.

### Roadmap notes (deferred)

Not in v0.3.0; anticipated for v0.4.0+:

- AWS Organizations / multi-account capability (deploy in delegated
  admin, scan members via cross-account roles).
- `terraform test` test suites per module. The framework now has
  `python-ci.yml` for Lambda code quality; Terraform's own native
  test framework is the next step.
- Rightsizing recommendation pipeline (Compute Optimizer + Cost
  Optimization Hub findings → DDB STATE+ACTION lifecycle, mirrors
  `idle-resource-cleanup`).
- Migration of DDB `hash_key` / `range_key` to the v6-provider
  `key_schema` form once the upstream syntax stabilises (currently
  kept on the deprecated form per per-module `dynamodb.tf` comments —
  apply works fine, warning persists).

## [0.2.1] — 2026-05-30

The "Solidus" release. The framework gets a name, a license, a complete
set of open-source governance files, and two real runtime additions:
the budgets burn-rate metric-math alarm that had been declared but never
built, and X-Ray Active tracing on every Lambda.

**Static-analysis status as of this tag:**

- `terraform fmt -recursive` — clean
- `terraform validate` — green on root + all 4 examples
- `tflint --recursive` — **zero issues**
- `checkov` with `soft_fail: false` in CI — **zero unsuppressed
  failures**. Every suppression carries an inline `# checkov:skip=`
  comment plus a matching subsection in
  [docs/COMPLIANCE_NOTES.md](docs/COMPLIANCE_NOTES.md)
  "Documented Checkov suppressions".

CI hard-enforces all of the above — no advisory checks remain.

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
- **X-Ray Active tracing** on every Lambda the framework deploys
  (`alerting/dispatcher`, `budgets/performance`,
  `cost-data-exports/health_check`, `finops-metrics/aggregator`,
  6× `idle-resource-cleanup/*`, `instance-scheduler/scheduler` +
  `discovery`, `tag-governance/untagged_cost`). Gated by a per-module
  `xray_tracing_enabled` variable defaulting to `true`. Adds
  `tracing_config { mode = "Active" }` to each Lambda plus the
  `xray:PutTraceSegments` + `xray:PutTelemetryRecords` IAM permissions
  via `concat()`. CloudWatch cost impact at framework volume is
  negligible (~$0.01/month).
- **Reserved concurrency** opt-in via a per-module
  `reserved_concurrent_executions` variable (default `null` = no
  reservation). Set to a positive integer to cap, or `-1` to disable
  invocations entirely — useful as a kill switch during incidents.
- **AWS Glue security configuration** (`aws_glue_security_configuration.cur`)
  on the CUR crawler in `cost-data-exports`. SSE-KMS for the crawler's
  S3 reads, SSE-KMS for its CloudWatch Logs, CSE-KMS for its job
  bookmarks. Attached to the crawler via `security_configuration`.
- **S3 abort-incomplete-multipart-upload** rule on the
  `cost-data-exports/athena_results` bucket lifecycle
  (`days_after_initiation = 7`) — prevents orphaned multipart uploads
  from accumulating silent storage charges.
- **S3 versioning** on the `cost-data-exports/athena_results` and
  `tag-governance/config` buckets. The `cost_data` bucket was already
  versioned; the other two now match. Athena-results noncurrent
  versions clean up after 7 days; Config noncurrent versions after 90.
- **New `aws_s3_bucket_lifecycle_configuration.config`** in
  `tag-governance` — 90-day noncurrent-version cleanup + 7-day
  multipart abort. Closes a real gap (the Config delivery bucket had
  no lifecycle config at all).
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
- **`log_retention_days >= 365` validation on every module.** Each
  module's `log_retention_days` variable now has a `validation` block
  that rejects sub-365 retention at `terraform plan` time. Aligns with
  Checkov CKV_AWS_338 and most regulatory regimes' 1-year audit-log
  minimum. The framework's defaults were already 365 — this just
  prevents accidental overrides.
- **`instance-scheduler` log_retention_days validation tightened** —
  previously accepted any valid CloudWatch retention value; now only
  values ≥ 365.
- **Root `providers.tf` simplified** — removed the `us_east_1` provider
  alias that was inherited from CUR v1 days. CUR 2.0 via BCM Data
  Exports is region-agnostic at the Terraform layer; no module uses
  the alias. Left a comment explaining when to add it back
  (CloudFront / ACM-for-CloudFront only).
- **Root `locals.tf` cleanup** — dropped the orphaned `local.kms_key_id`
  (only `kms_key_arn` is actually consumed).

### Fixed

- **tflint runtime blocker** at `modules/alerting/main.tf:418` — the
  `aws_dynamodb_table_invalid_stream_view_type` rule was misfiring on
  `for_each` over `cty.EmptyObjectVal.Mark(marks.Sensitive)`. Fixed by
  the `nonsensitive(toset(keys(...)))` restructure above.
- **28 tflint warnings** across the original sweep + the two
  follow-ups:
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
  - Unused `local.kms_key_id` at the root (removed)
  - Unused `aws.us_east_1` provider alias at the root (removed)
- **Checkov: 0 unsuppressed failures.** Five rule categories fixed in
  code, six categories suppressed with inline `# checkov:skip=<rule>`
  comments and AWS-doc-cited justifications. The fixed categories add
  real runtime behaviour (X-Ray tracing, Glue security config, S3
  abort-multipart). The suppressed categories are either AWS-imposed
  limitations (resource-level perms not supported for the actions the
  framework needs) or enterprise-only features (AWS Signer code-signing)
  that are out of scope for this version. Every suppression carries:
  - **Inline rationale** at the resource definition
  - **A subsection in [docs/COMPLIANCE_NOTES.md](docs/COMPLIANCE_NOTES.md)**
    under "Documented Checkov suppressions" — auditors get one page that
    lists every suppression with rule, location, why, mitigation, and
    AWS-doc link
  - **Where applicable, mitigation in code** — e.g. instance-scheduler
    + idle-cleanup tag-based runtime filtering, Budget Actions trust
    policy locking the role to `budgets.amazonaws.com` only

  | Rule | Treatment | Where |
  |---|---|---|
  | CKV_AWS_50 (X-Ray tracing) | **Code fix** — `tracing_config { mode = "Active" }` on all 8 Lambdas | all Lambda resources |
  | CKV_AWS_115 (reserved concurrency) | **Code fix** (opt-in) — `reserved_concurrent_executions` variable per module | all Lambda resources |
  | CKV_AWS_195 (Glue security configuration) | **Code fix** — new `aws_glue_security_configuration.cur` | `cost-data-exports` |
  | CKV_AWS_300 (S3 abort multipart) | **Code fix** — `abort_incomplete_multipart_upload { days_after_initiation = 7 }` | `cost-data-exports/athena_results` lifecycle |
  | CKV_AWS_338 (log retention ≥ 1y) | **Variable validation + inline skip** — `>= 365` enforced at plan time on every module; static `checkov:skip` because Checkov can't evaluate variable validations | all 8 `aws_cloudwatch_log_group` resources |
  | CKV_AWS_272 (Lambda code-signing) | **Suppressed** — enterprise opt-in via AWS Signer; not modelled. Mitigated by pinning module ref | all 8 Lambda resources |
  | CKV_AWS_286, 288, 289, 290, 355 (Budget Actions IAM) | **Suppressed** — AWS Budget Actions is a managed service; permissions are AWS-documented requirements; trust policy locks role to `budgets.amazonaws.com` only | `budgets/aws_iam_role_policy.budget_actions` |
  | CKV_AWS_290, 355 (IAM `*` for EC2/RDS/ASG/ELB) | **Suppressed** — AWS doesn't support resource-level perms for the start/stop/delete actions these Lambdas need; scope enforced via tag-based runtime filtering | `instance-scheduler/iam.tf`, `idle-resource-cleanup/main.tf` |
  | CKV_AWS_288, 290, 355 (Athena/Glue read) | **Suppressed** — Athena `StartQueryExecution`/`GetQueryResults` + Glue `GetDatabase`/`GetTable`/`GetPartitions` don't accept resource-level constraints | `tag-governance/aws_iam_role_policy.untagged_cost` |
  | CKV_AWS_21 (S3 versioning on athena_results + config) | **Code fix** — added `aws_s3_bucket_versioning` to both | `cost-data-exports`, `tag-governance` |
  | CKV2_AWS_61 (S3 lifecycle on config) | **Code fix** — added `aws_s3_bucket_lifecycle_configuration.config` | `tag-governance` |
  | CKV_AWS_18 (S3 access logging) | **Suppressed** — CloudTrail S3 data events at the org level provide the audit-grade access log; S3 access logging would create a chicken-and-egg problem | all three framework S3 buckets |
  | CKV_AWS_144 (S3 cross-region replication) | **Suppressed** — overkill for FinOps data (CUR can be regenerated by AWS, query results are ephemeral, Config history can replay from CloudTrail) | all three framework S3 buckets |
  | CKV2_AWS_62 (S3 event notifications) | **Suppressed** — none of the three buckets have event-driven downstream consumers | all three framework S3 buckets |
  | CKV_AWS_145, CKV2_AWS_6, CKV2_AWS_61 (false positives on companion-resource linkage) | **Suppressed** — KMS encryption, public-access block, and lifecycle ARE configured via the corresponding `aws_s3_bucket_*` companion resources; Checkov 3.x sometimes fails to trace the linkage | `cost-data-exports/athena_results`, `tag-governance/config` |
  | CKV2_AWS_45, CKV2_AWS_48 (Config recorder) | **Suppressed** — false positives: `all_supported = true` is literal, `include_global_resource_types` defaults to `true` via variable, `is_enabled = true` is literal | `tag-governance/aws_config_configuration_recorder*` |
  | CKV2_AWS_57 (Secrets Manager rotation) | **Suppressed** — the secrets hold third-party webhook URLs / integration keys that the third parties don't expose rotation APIs for (Slack, Teams, PagerDuty, Opsgenie, generic webhooks) | `alerting/aws_secretsmanager_secret.{slack,teams,pagerduty,opsgenie,webhook}` |

### Verification

- `terraform fmt -recursive` clean
- `terraform validate` green on root + all 4 examples
  (only the persistent DDB `hash_key`/`range_key` deprecation warnings
  in `idle-resource-cleanup` remain — that's an AWS-provider migration
  deferred per [modules/idle-resource-cleanup/main.tf](modules/idle-resource-cleanup/main.tf) comments)
- `tflint --recursive --format compact` clean (28 warnings + 1 runtime
  blocker from the original sweep all resolved)
- **Checkov: 0 unsuppressed failures** — original 114 findings + 78
  follow-up findings all addressed. All inline `# checkov:skip=`
  comments placed correctly inside resource blocks (the v0.2.1-draft
  placement above the block was a latent bug — Checkov requires
  comments inside the resource).
- Python syntax check passes on all 16 Lambda files
- Zero `var.<old_name>` references in any `.tf`, `.tfvars`, or `.md` file

### Migration from v0.1.0

No breaking changes. The variable surface is backwards-compatible.
Update consumers by:

1. `git pull` the new tag
2. `terraform init` (picks up the new `versions.tf` files)
3. `terraform plan` will show:
   - **One new alarm** (`aws_cloudwatch_metric_alarm.burn_rate_low`)
     inside the `budgets` module, only if you have ≥ 1 budget AND
     `budgets_performance_tracking_enabled = true` AND
     `budgets_burn_rate_alarm_days_to_breach != null` (default 7).
     Disable by setting `budgets_burn_rate_alarm_days_to_breach = null`.
   - **One new resource per CUR setup**
     (`aws_glue_security_configuration.cur`) if
     `cost_data_exports_athena_enabled = true`.
   - **New `aws_s3_bucket_versioning.athena_results`** if
     `cost_data_exports_athena_enabled = true`. Existing query results
     stay untouched; only newly-written results get versioned.
   - **New `aws_s3_bucket_versioning.config`** +
     **`aws_s3_bucket_lifecycle_configuration.config`** if
     `tag_governance_enabled = true` and the framework manages the
     Config recorder. Cleans up noncurrent Config delivery versions
     after 90 days.
   - **In-place updates on every Lambda** — `tracing_config { mode =
     "Active" }` block added, `reserved_concurrent_executions =
     null` field added. No replacement; no downtime. Disable X-Ray by
     setting the per-module `xray_tracing_enabled = false`.
   - **In-place update on every Lambda IAM role policy** — two new
     statements added for `xray:PutTraceSegments` +
     `xray:PutTelemetryRecords`. Drops away if you disable X-Ray.
   - **In-place update on the `athena_results` S3 lifecycle** — adds
     the `abort_incomplete_multipart_upload` rule.
   - **Minor in-place updates to the `aws_secretsmanager_secret*`
     resources** if any are present — the
     `nonsensitive(toset(keys(...)))` restructure doesn't change
     resource identity, only the iteration expression in the plan diff.
4. If you were passing `log_retention_days < 365` to any module,
   `terraform plan` will now fail with a clear validation error.
   Either bump the value to ≥ 365 or set
   `xray_tracing_enabled = false` to disable the new behaviour — both
   knobs are documented in each module's variables.tf.

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

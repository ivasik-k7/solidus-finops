# Contributing to Solidus FinOps

Thank you for taking the time to contribute. This framework manages live
AWS infrastructure, encryption keys, and audit-defensible cost data —
so the bar for code that lands on `main` is deliberately high.

This document explains the contribution flow, the conventions every PR
must respect, and the checks the CI pipeline enforces.

## Code of Conduct

By participating in this project you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting security issues

**Do not open public issues for security vulnerabilities.** See
[SECURITY.md](SECURITY.md) for the private reporting flow.

---

## How to contribute

### 1. Pick or open an issue first

For anything beyond a typo or a trivial fix, open an issue (or comment on
an existing one) before sending a PR. The framework has architectural
invariants — encryption-at-rest, off-by-default destructive automation,
the strict variable-naming convention, the DDB STATE+ACTION audit pattern —
that aren't obvious from any single file. A 60-second discussion up front
avoids 60 minutes of rework on a misaligned PR.

### 2. Branch

Branch from `main` with a descriptive prefix:

| Prefix | Use for |
|---|---|
| `feat/` | New capability or module |
| `fix/` | Bug fix that doesn't change the variable contract |
| `docs/` | Documentation-only change |
| `refactor/` | No behaviour change |
| `chore/` | CI, tooling, dependency bumps |
| `breaking/` | Anything that changes a variable name, removes an output, or alters resource lifecycle (forces replacement) |

### 3. Make the change

Follow the conventions below.

### 4. Open a PR using the template

The PR template (`.github/PULL_REQUEST_TEMPLATE.md`) is a checklist of
what reviewers will check. Mark every applicable box.

### 5. Get it merged

- All CI checks must pass (see [CI checks](#ci-checks) below).
- At least one approving review is required.
- Squash-merge is preferred so `main` history matches one feature = one
  commit.

---

## Conventions

### Naming

Solidus FinOps uses a **strict `<module>_<name>` prefix** on every
submodule variable at the root level. Booleans use the suffix form
`<module>_enabled` (NOT `enable_<module>`). Only truly cross-cutting
concerns (`namespace`, `environment`, `stack_name`, `aws_primary_region`,
`aws_secondary_regions`, `create_kms_key`, `log_retention_days`,
`lambda_runtime`) are un-prefixed.

```hcl
# Correct
variable "instance_scheduler_enabled" { type = bool }
variable "instance_scheduler_max_actions_per_tick" { type = number }

# Wrong
variable "enable_instance_scheduler" { type = bool }   # legacy prefix
variable "scheduler_enabled" { type = bool }           # module slug missing
```

The framework-wide [CHANGELOG.md](CHANGELOG.md) and the per-module
CHANGELOGs document this convention; PRs that violate it are not merged.

### Module file structure

New modules follow the file split established by `instance-scheduler` and
`finops-metrics`:

```
modules/<module>/
├── main.tf           header comment only — no resources
├── versions.tf       required_version + required_providers (lower bounds only)
├── variables.tf      every input + validation block
├── outputs.tf        every output
├── locals.tf         computed locals (env vars, predicates)
├── data.tf           data sources (only what's actually used)
├── iam.tf            roles + policies
├── <service>.tf      one file per AWS service concern
├── lambda.tf         if the module has Lambdas
├── eventbridge.tf    schedules / rules
├── cloudwatch.tf     alarms + dashboards
├── sqs.tf            DLQs
├── dynamodb.tf       audit / state tables (STATE + ACTION pattern)
├── lambda/           Python source — packaged via archive_file
├── docs/EDGE_CASES.md  every operational edge case the module handles
├── CHANGELOG.md      SemVer per-module history (Keep a Changelog format)
└── README.md         standalone-usage + module-layout + features
```

Smaller modules (e.g. `alerting`, `budgets`) keep a single `main.tf` for
historical reasons but add `versions.tf` explicitly.

### Architectural invariants

These are not negotiable:

- **Off-by-default destructive automation.** Lambdas that can delete or
  stop production resources default to `enabled = false` AND `dry_run = true`.
- **Encryption at rest is default.** Every S3 bucket uses a CMK (not
  SSE-S3). Every SNS topic, DynamoDB table, CloudWatch log group is
  CMK-encrypted. Webhooks live in Secrets Manager.
- **No silent failure.** Every Lambda has a DLQ + a CloudWatch error
  alarm + a DLQ-depth alarm.
- **DDB STATE + ACTION audit pattern.** Any module that mutates AWS
  state writes one STATE row per resource (with TTL ~90 days) and one
  append-only ACTION row per action (with TTL ~7 years for regulatory
  workloads).
- **`prevent_destroy` on data resources.** KMS keys, the cost-data S3
  bucket, and the audit DDB tables carry `lifecycle { prevent_destroy = true }`.
- **Standalone-reusable.** A module's `events_topic_arn` input should be
  optional (NULL = skip SNS publish; metrics / DDB / dashboards still
  work) unless there's a hard architectural reason it can't be.
- **No hardcoded regional rate tables.** Dollar-value reporting belongs
  in the analytics layer (Cloudability / CUR / BI). The framework emits
  action counts + DDB audit rows; pricing joins happen elsewhere.

### Documentation

- New modules ship `README.md` + `CHANGELOG.md` + `docs/EDGE_CASES.md`.
- Per-module `CHANGELOG.md` uses [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
  format with `Added` / `Changed` / `Fixed` / `Removed` / `Deprecated` / `Security`
  sections.
- Framework-wide [CHANGELOG.md](CHANGELOG.md) entry required for any
  change that touches the root variable contract or adds/removes a
  module.
- Update [docs/PHASES.md](docs/PHASES.md) when adding a new
  `<module>_enabled` flag — show which Crawl / Walk / Run phase it belongs in.
- Update [docs/COST_ESTIMATE.md](docs/COST_ESTIMATE.md) when adding a
  new Lambda, DDB table, S3 bucket, or anything else with a recurring
  cost.

### Diagrams

If the change adds a module or alters the data flow, regenerate:

```bash
pip install -r diagrams/requirements.txt   # plus graphviz at the OS level
cd diagrams && python framework_structure.py && python aws_architecture.py
```

Both PNG and SVG outputs are committed.

---

## Local development

### Prerequisites

- Terraform `>= 1.6.0`
- Python `>= 3.10` (for Lambda code + diagram generation)
- `tflint` (for `tflint --recursive`)
- `graphviz` (for diagram rendering, OS-level install)
- An AWS account you're allowed to break, for manual `terraform plan` testing

### Pre-commit

```bash
pip install pre-commit
pre-commit install
```

The hooks in [.pre-commit-config.yaml](.pre-commit-config.yaml) run
`terraform fmt`, `terraform validate` (per module), `tflint`, and a
Python syntax check on every commit.

### Useful one-liners

```bash
# Format every .tf file in the tree
terraform fmt -recursive

# Validate root + every example
terraform init -backend=false
terraform validate
for d in examples/*/; do
  (cd "$d" && terraform init -backend=false -no-color && terraform validate)
done

# Syntax-check every Lambda Python file
find modules -name "*.py" -type f -exec python3 -c "import ast; ast.parse(open('{}').read())" \;

# Find stale references to deleted modules / old variable names
grep -rln "enable_anomaly_detection\|enable_compute_optimizer\|cost_categories\b" .
```

---

## CI checks

Pull requests run [.github/workflows/terraform-ci.yml](.github/workflows/terraform-ci.yml).
Every job must pass before merge:

| Job | What it checks |
|---|---|
| `terraform fmt` | `terraform fmt -check -recursive` is clean |
| `terraform validate` | Root + every `examples/*` validate cleanly with `-backend=false` |
| `tflint` | `tflint --recursive --format compact` reports zero issues |
| `python-syntax` | Every `modules/*/lambda/*.py` parses |
| `checkov` (advisory) | Security scan; failures are reviewed, not auto-blocking |

PRs that change a module's runtime contract (variables, outputs, Lambda
env vars) must also update the module's `CHANGELOG.md` — the CI job
checks the changelog file's mtime against the changed files.

---

## Releasing

Versions are tagged on `main` after the framework-level
[CHANGELOG.md](CHANGELOG.md) is updated:

1. Update `[Unreleased]` → `[X.Y.Z] — YYYY-MM-DD`
2. Add `Added` / `Changed` / `Fixed` / `Removed` sections
3. Add a `Migration from vX.Y.Z-1` section if anything changes the
   variable contract or alters resource lifecycle
4. Open a release PR
5. After merge, tag the merge commit `vX.Y.Z`
6. Push the tag

Per-module CHANGELOGs are versioned independently — a change to
`modules/instance-scheduler` increments that module's version
independently of the framework version.

---

## Style preferences (smaller things)

- Run `terraform fmt`; the CI fails otherwise.
- Use heredoc multi-line strings for long descriptions in variables.
- Prefer `concat(...)` for conditional IAM statements over `dynamic` blocks
  (proven readable in the existing modules).
- Lambda Python: use `from __future__ import annotations`, modern
  `datetime.now(timezone.utc)` instead of `utcnow()`, adaptive boto3
  retries (`Config(retries={"max_attempts": 10, "mode": "adaptive"})`).
- Avoid adding upper bounds to `required_providers` versions — lower
  bounds only in reusable modules.
- Per-resource `try/except` inside scanning Lambdas — one bad resource
  must never poison the tick.

Thanks for reading this far. PRs that follow the conventions above tend
to merge in days, not weeks.

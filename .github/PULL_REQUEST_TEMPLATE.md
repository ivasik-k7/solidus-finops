<!--
Thanks for contributing to Solidus FinOps. This template is a checklist
of what reviewers will check — mark every applicable box, and replace
the placeholders below before opening the PR.

For trivial changes (typo, formatting, comment-only): keep the Summary
section, delete the rest.
-->

## Summary

<!-- 1–3 sentences. What changed and why. Reviewers should be able to
understand the intent without opening the diff. -->

## Type of change

- [ ] `feat` — new module or capability
- [ ] `fix` — bug fix without contract change
- [ ] `docs` — documentation-only
- [ ] `refactor` — no behaviour change
- [ ] `chore` — CI / tooling / dependency bump
- [ ] `breaking` — changes variable names, removes outputs, or forces resource replacement

## Linked issue

Closes #<issue-number> <!-- or "Refs #..." if this is a partial fix -->

## What changed (concrete)

<!-- Bullet points: file paths + the specific thing that changed. Skip
generic ones like "various files". Be specific. -->

- `modules/<module>/<file>.tf` — ...
- `variables.tf` — ...
- `docs/<file>.md` — ...

## Conventions checklist

- [ ] Variable names follow strict `<module>_<name>` prefix; booleans use the `<module>_enabled` suffix form
- [ ] No upper bounds added to any `required_providers` version constraint
- [ ] New modules ship `versions.tf`, `variables.tf`, `outputs.tf`, `locals.tf`, `data.tf`, `README.md`, `CHANGELOG.md`, and `docs/EDGE_CASES.md`
- [ ] Lambda Python uses `from __future__ import annotations`, modern `datetime.now(timezone.utc)`, adaptive boto3 retries, per-resource `try/except`
- [ ] DDB tables that hold audit data have `prevent_destroy = true`, KMS encryption, and PITR enabled
- [ ] Destructive Lambdas default to `enabled = false` AND `dry_run = true`

## Architectural invariants

Confirm none of the following invariants were broken (or document why
if they were, in the *Migration* section below):

- [ ] **Encryption at rest** — every new S3 bucket, SNS topic, DDB table, log group is CMK-encrypted
- [ ] **No silent failure** — every new Lambda has a DLQ + a CloudWatch error alarm + a DLQ-depth alarm
- [ ] **No hardcoded regional rate tables** — dollar-value reporting deferred to the analytics layer
- [ ] **Standalone-reusable** — new modules accept `events_topic_arn = null` if architecturally possible

## CI checks expected to pass

- [ ] `terraform fmt -check -recursive` (run locally before pushing)
- [ ] `terraform validate` on root + every `examples/*`
- [ ] `tflint --recursive --format compact` clean
- [ ] Every `modules/*/lambda/*.py` syntax-checks (Python AST parse)

## Documentation

- [ ] Affected module's `README.md` updated
- [ ] Affected module's `CHANGELOG.md` updated (Keep a Changelog format)
- [ ] Affected module's `docs/EDGE_CASES.md` updated if behaviour changed
- [ ] Framework-level [`CHANGELOG.md`](../CHANGELOG.md) updated if the change touches the root variable contract
- [ ] [`docs/PHASES.md`](../docs/PHASES.md) updated if a new `<module>_enabled` flag was added
- [ ] [`docs/COST_ESTIMATE.md`](../docs/COST_ESTIMATE.md) updated if anything with recurring cost was added (new Lambda, DDB table, S3 bucket, etc.)
- [ ] Diagrams regenerated (`cd diagrams && python framework_structure.py && python aws_architecture.py`) if the data flow changed

## Migration (for breaking changes only)

<!-- If this PR is `breaking`, describe what existing consumers must
change. Include before/after HCL snippets, the rationale, and any
`moved {}` blocks added. Delete this section if not applicable. -->

## Test plan

<!-- How did you verify this works? -->

- [ ] `terraform plan` against a real AWS account: <!-- describe what the plan showed -->
- [ ] Lambda manually invoked: <!-- which Lambda, what input, what output -->
- [ ] N/A — documentation-only change

## Screenshots / output (if relevant)

<!-- Dashboard screenshots, CloudWatch log excerpts, terraform plan
output, etc. Redact sensitive values. -->

## Security considerations

<!-- Anything reviewers should look at twice: new IAM permissions, new
resources with `Resource = "*"`, new external network calls, new
sensitive data flows. Write "None" if nothing applies. -->

None.

---

By submitting this pull request, I confirm that my contribution is made
under the terms of the Apache License 2.0 (see [LICENSE](../LICENSE)) and
that I have read and agree to the [Code of Conduct](../CODE_OF_CONDUCT.md).

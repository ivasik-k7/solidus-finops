# Solidus FinOps — OpenSSF Scorecard Hardening

**Audience:** Future maintainer of this repo (or the current one a year
from now) who needs to understand why each Scorecard heuristic is
configured the way it is, and how to keep the score from regressing.
**As-of:** 2026-05-31. **Current score:** 5.7 / 10. **Target:** 9 +.

OpenSSF Scorecard is a credibility signal for enterprise / regulated
adopters. A high score does not make this framework secure — the
substantive work lives in [THREAT_MODEL.md](THREAT_MODEL.md),
[COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md), and the per-resource
Checkov suppressions. But a low score raises questions during a vendor
security review, and questions cost time. The intent of this document
is to make every Scorecard heuristic legible: what it checks, what
Solidus FinOps does about it, and what the maintainer needs to keep
doing.

For background:

- Scorecard methodology: <https://github.com/ossf/scorecard>
- Per-check definitions: <https://github.com/ossf/scorecard/blob/main/docs/checks.md>
- Live score for this repo: <https://scorecard.dev/viewer/?uri=github.com/ivasik-k7/solidus-finops>

---

## 1. Per-heuristic status

The table below covers every Scorecard check Scorecard runs on a public
repository. Severity follows the upstream classification.

| Heuristic | Severity | Current | Owner | Status | Action to lift |
|---|---|---|---|---|---|
| Binary-Artifacts | high | 10 | code | done | — |
| Branch-Protection | high | 0 | repo-settings | blocked | Run `scripts/setup-branch-protection.sh` (requires admin token) |
| CI-Tests | high | ? | external | time-based | First merged PR after v0.3.0 lifts this; nothing to do |
| CII-Best-Practices | low | 0 | external | blocked | Submit project to bestpractices.dev |
| Code-Review | high | 0 | repo-settings | blocked | Same script as Branch-Protection (review-required is part of the ruleset) |
| Contributors | low | 0 | external | time-based | Recruit 1 + external contributor; commit `CONTRIBUTORS.md` |
| Dangerous-Workflow | critical | 10 | code | done | — |
| Dependency-Update-Tool | high | 10 | code | done | `.github/dependabot.yml` already present |
| Fuzzing | medium | 0 | code | blocked | Out of scope for IaC framework (no executable surface) |
| License | low | 10 | code | done | — |
| Maintained | high | 0 | external | time-based | Commit at least once every 4 – 6 weeks (docs counts) |
| Packaging | medium | ? | external | partial | Framework distributes by git tag; no package registry — accept the `?` |
| Pinned-Dependencies | medium | 0 | code | partial | Replace every `uses: org/action@vN` with a SHA pin + version comment |
| SAST | medium | 10 | code | done | `security.yml` runs CodeQL + Semgrep + Bandit |
| Security-Policy | low | 10 | code | done | `SECURITY.md` present |
| Signed-Releases | high | ? | code | partial | Add `actions/attest-build-provenance` step to `release.yml` |
| Token-Permissions | high | 10 | code | done | All workflows set top-level `permissions:` + per-job overrides |
| Vulnerabilities | high | 10 | external | done | No open advisories on direct deps |
| Webhooks | low | 10 | repo-settings | done | No outbound webhooks configured |

Symbols:
✅ done · 🟡 partial · ❌ blocked · ⏳ time-based.

Of the eighteen heuristics, eight are already at 10 / 10. The remaining
items below have one section each.

---

## 2. Branch-Protection

**What it checks.** Whether the default branch (and any release
branches) is protected against direct pushes, requires status checks,
requires up-to-date branches, and disallows force-pushes and deletions.
The check reads the GitHub branch-protection / ruleset API; if the
caller token lacks `admin:repo` it returns an inconclusive result that
Scorecard scores as 0.

**Why it matters.** This is the single highest-impact missing control
on the repo today. Enterprise reviewers infer code-tampering posture
from this score; an unprotected default branch on a framework that
provisions IAM-modifying Budget Actions is a red flag.

**Current state.** The default branch is `main`. As of 2026-05-31 it
has no ruleset attached. The maintainer has admin on the repo; what is
missing is the one-shot script to apply the ruleset reproducibly.

**Fix — repo setting.** Run `scripts/setup-branch-protection.sh`. The
script uses `gh api` to PUT a ruleset that enforces:

- `required_pull_request_reviews.required_approving_review_count = 1`
- `required_pull_request_reviews.require_code_owner_reviews = true`
- `required_pull_request_reviews.dismiss_stale_reviews = true`
- `required_status_checks.strict = true` (PRs must be up-to-date)
- `required_status_checks.contexts` includes the four CI jobs:
  `terraform-ci / validate`, `python-ci / test`, `security / codeql`,
  `docs-quality / markdownlint`
- `enforce_admins = true`
- `required_linear_history = true`
- `required_signatures = false` (see §10 for the rationale)
- `allow_force_pushes = false`
- `allow_deletions = false`

Run it once after cloning admin credentials into `gh auth login`:

```bash
./scripts/setup-branch-protection.sh
```

The script is idempotent; rerunning it after a defensive check
(see §9) is safe.

---

## 3. Code-Review

**What it checks.** Of the last ~30 merged PRs to the default branch,
how many had at least one reviewer other than the author, with an
approving review recorded? Scorecard reads the GitHub Reviews API.

**Why it matters.** Solidus FinOps is a single-maintainer project. The
heuristic is biased against single-maintainer repositories — Ivan
cannot review his own PR. The lift comes from configuring branch
protection such that a PR cannot land without a recorded review, then
either (a) recruiting an external reviewer or (b) accepting that the
score reflects the maintainer count.

**Current state.** Same as Branch-Protection: no review requirement
enforced. The `CODEOWNERS` file at `.github/CODEOWNERS` already routes
every path to `@ivankovtun`, so the moment branch protection enables
`require_code_owner_reviews`, every PR will require a review by
default.

**Fix — repo setting + workflow.** The same
`scripts/setup-branch-protection.sh` covers the technical control. The
human side: when the project gains a second maintainer, add them to
`CODEOWNERS` under the appropriate paths (the file is already
sectioned by surface area: root composition, docs, per-module,
security-sensitive, CI). For paths flagged as security-sensitive
(`**/iam.tf`, `**/kms*.tf`, `/.github/`, `/LICENSE`, `/NOTICE`,
`/SECURITY.md`) consider raising the approving-review count to 2 in
the ruleset once a co-maintainer exists.

CODEOWNERS interacts with branch protection in one important way:
without `require_code_owner_reviews = true`, CODEOWNERS is advisory
only and Scorecard's Code-Review check will still score 0 on
self-merged PRs.

---

## 4. Maintained

**What it checks.** Scorecard looks at the trailing 90 days of repo
activity (commits + issues + PR merges). A repo with 0 commits and 0
issue activity in 90 days scores 0; a repo with at least one commit
and one issue / PR interaction per ~30 days scores 10.

**Why it matters.** "Maintained" is the leading question on every
vendor security questionnaire. If the score drifts to 0 because the
maintainer was busy for a quarter, every downstream consumer sees a
"unmaintained" badge before they see the actual codebase.

**Current state.** Active development. The risk is silent regression
during quiet quarters.

**Fix — process.** Commit something at least every 4 – 6 weeks. The
commit does not have to be code: documentation updates, dependency
bumps merged via Dependabot, or a CHANGELOG entry all count. The
practical rule:

- Dependabot PRs landing on schedule will keep this score green
  on their own, provided they are reviewed and merged rather than
  ignored.
- If Dependabot is paused (e.g. during a freeze) and no other commits
  land for 30 days, push a docs update.

There is no script for this; it is a maintainer habit.

---

## 5. Pinned-Dependencies

**What it checks.** Every `uses: <org>/<action>@<ref>` in every
workflow under `.github/workflows/`. Scorecard wants `<ref>` to be a
40-character commit SHA, not a tag like `@v4`. Tags are mutable — a
malicious push to `v4` could replace the action's code on the next
workflow run. SHA pinning makes the supply-chain dependency
content-addressed.

**Why it matters.** This is the most concrete supply-chain control the
framework can demonstrate, and the cheapest one to fix. The fix is
mechanical: replace each `@v4` with the commit SHA, and leave the
human-readable tag as a trailing comment so reviewers know which
version they are looking at.

**Current state.** All eight workflows currently pin to major-version
tags (`@v4`, `@v2`, etc.). Scorecard scores this 0 because none of
them are SHA-pinned.

**Fix — code.** For each action reference, replace:

```yaml
- uses: actions/checkout@v4
```

with:

```yaml
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
```

Dependabot is configured (`.github/dependabot.yml`) with
`open-pull-requests-limit: 10` against the `github-actions` ecosystem.
When an action publishes a new SHA, Dependabot opens a PR that updates
**both the SHA and the trailing version comment** in lockstep — this
is the behaviour introduced in Dependabot's `2024-Q3` release. The
maintainer reviews the diff and merges; no manual SHA lookup is
required during steady-state operation.

Initial conversion (one-time):

```bash
# For each action in each workflow, look up the SHA for the
# tagged version you currently use:
gh api repos/actions/checkout/git/ref/tags/v4.1.1 \
  --jq '.object.sha'
```

After conversion, run `scripts/check-action-pins.sh` (planned) in CI
to fail the build if any workflow ever reintroduces a tag-only pin.
Until that script exists, the convention is enforced by review.

---

## 6. Fuzzing

**What it checks.** Whether the repository integrates with a fuzzing
service (OSS-Fuzz, ClusterFuzzLite, etc.) or has language-native fuzz
targets (`go test -fuzz`, `cargo fuzz`, etc.).

**Why it matters for Solidus FinOps.** It does not. Solidus FinOps is
an Infrastructure-as-Code framework: Terraform HCL, a handful of
Python Lambdas invoked by AWS event sources, and shell scripts that
run during deployment. There is no parser, no protocol implementation,
no untrusted-input deserialiser exposed to the open internet, and no
sustained executable surface to fuzz. The Lambdas receive structured
events from AWS service principals (EventBridge, S3, SNS) whose
payloads are schema-validated at the API boundary.

**Current state.** No fuzz targets. Score: 0.

**Fix.** Accept the 0. Document the rationale here so a reviewer
asking "why no fuzzing?" finds the answer without escalating.

If at some point the framework grows a long-running HTTP listener
(e.g. a webhook receiver in front of Slack instead of the current
one-way SNS → Slack fanout), revisit this: that listener would be a
legitimate fuzz target and ClusterFuzzLite is the path of least
resistance.

---

## 7. CII-Best-Practices

**What it checks.** Whether the project has earned a CII (now OpenSSF)
Best Practices badge at <https://bestpractices.dev>. The check reads
the API for a project entry with `repo_url` matching this repo. No
entry → score 0.

**Why it matters.** Low severity — it is essentially a
self-attestation badge. But it is cheap to obtain (one form), and a
"passing" badge in the README is the kind of signal an enterprise
procurement team likes to see during initial triage.

**Current state.** No project entry on bestpractices.dev.

**Fix — external action.** Submit at
<https://www.bestpractices.dev/en/projects/new>. Suggested metadata
for the form:

| Field | Value |
|---|---|
| Project URL | `https://github.com/ivasik-k7/solidus-finops` |
| Project name | Solidus FinOps |
| Description | Terraform framework for AWS FinOps: cost data exports, budgets, tag governance, idle-resource cleanup, instance scheduling, alerting. |
| Primary language | HCL (Terraform) |
| Natural language | EN |
| License | Apache-2.0 |
| Maintainer | Ivan Kovtun |

After submission, work through the "passing" criteria checklist; most
items are already satisfied (CONTRIBUTING, SECURITY, LICENSE, CI,
release notes). Add the resulting badge to README.md.

---

## 8. Contributors

**What it checks.** Whether the project has commits from contributors
across multiple GitHub organisations or companies (the heuristic looks
at the contributor's affiliation field on GitHub). One-org or
single-author repos score 0.

**Why it matters.** Low severity, but it is a structural problem for
single-maintainer open-source projects. The signal Scorecard is trying
to measure — "is anyone outside the originating org reviewing this
code?" — is legitimate. A single external contributor with an
unaffiliated GitHub account lifts the score.

**Current state.** Single-author. Score: 0.

**Fix — time-based.** Two things move this:

1. Recruit. Direct outreach to FinOps practitioners in adjacent
   communities (the FinOps Foundation, the AWS Cost & Usage Reports
   Slack, the Terraform AWS community). Even one merged docs PR from
   an external contributor is enough to lift this metric.
2. Track it. Add a `CONTRIBUTORS.md` file at repo root listing every
   external contributor with their GitHub handle. Scorecard does not
   parse this file directly — the score lifts because the underlying
   commit log shows multi-org activity — but it is the conventional
   place to thank contributors and makes the recruitment effort
   visible.

There is no code or workflow change for this one. It is patience plus
outreach.

---

## 9. Signed-Releases

**What it checks.** For the last ~5 releases, whether each release has
an associated cryptographic signature or attestation that Scorecard
can verify. The check looks for SLSA provenance attestations
(preferred), GPG signatures on release assets, or sigstore-signed
artifacts.

**Why it matters.** Solidus FinOps is consumed as pinned Terraform
module refs. A downstream user who pins
`source = "git::https://github.com/ivasik-k7/solidus-finops.git?ref=v0.3.0"`
is implicitly trusting that the contents at `v0.3.0` are what the
maintainer published. Provenance attestation makes that trust
verifiable: the consumer can prove the release asset was built from a
specific commit by a specific workflow run.

**Current state.** `release.yml` publishes a GitHub Release with the
extracted CHANGELOG section and (optionally) rendered diagrams. No
attestation step. Score: `?` (Scorecard cannot find a signature).

**Fix — code.** Add a build-provenance attestation step to
`release.yml`. After the diagram-assets step, before the
`softprops/action-gh-release` step, insert:

```yaml
- name: Generate build provenance attestation
  uses: actions/attest-build-provenance@v1
  with:
    subject-path: |
      diagrams/aws-architecture.png
      diagrams/aws-architecture.svg
      diagrams/framework-structure.png
      diagrams/framework-structure.svg
```

The job also needs the `attestations: write` and `id-token: write`
permissions added to the `permissions:` block. These two permissions
are scoped to the release job only — they are not granted at the
top-level `permissions:` map.

Downstream consumers verify the attestation with:

```bash
gh attestation verify diagrams/aws-architecture.svg \
  --owner ivasik-k7
```

Verification succeeds if the artifact's SHA-256 matches a recorded
attestation signed by the workflow's GitHub OIDC identity. SLSA Level
3 context: <https://slsa.dev/spec/v1.0/levels>.

Note: only release-bundled artifacts (the diagrams attached to the
Release) get attestation. The git tag itself is the source of truth
for module consumers, and tag content is already content-addressed via
its commit SHA — no separate attestation is needed for the source.

---

## 10. CI-Tests

**What it checks.** Of the last ~30 merged PRs, how many had at least
one passing CI check at the time of merge? Scorecard reads the GitHub
Checks API.

**Why it matters.** This is the single best signal that "PRs go
through CI before landing". It is also the most chicken-and-egg of
the heuristics: a repo that has only just enabled a CI matrix scores
`?` until enough PRs have landed through it to fill the heuristic
window.

**Current state.** `?`. The four primary CI workflows
(`terraform-ci.yml`, `python-ci.yml`, `security.yml`,
`docs-quality.yml`) are all active and have been triggering on PRs
since v0.3.0. There simply has not been enough PR-merge volume yet
for Scorecard to score the check confidently.

**Fix — time.** Nothing to change. The score will resolve to 10 once
the next handful of feature PRs lands through CI. The only failure
mode is the maintainer pushing directly to `main` to bypass CI —
which Branch-Protection (§2) closes off.

---

## 11. Packaging

**What it checks.** Whether the project publishes to a recognised
package registry (npm, PyPI, Maven Central, Crates.io, RubyGems,
Docker Hub / GHCR, etc.).

**Why it matters for Solidus FinOps.** It does not, directly.
Terraform modules are distributed by git-tag reference; there is no
"Terraform Module Registry" entry that Scorecard knows about (the
public Terraform Registry's API is not currently a recognised package
source for Scorecard).

**Current state.** Score: `?`. We are not going to publish to a
non-Terraform package registry purely to lift this score — that would
be dishonest signal.

**Fix.** Accept the `?`. If at some point the framework grows a
publishable companion (a Python CLI for local validation, for example),
publishing that to PyPI would lift this check. Until then, document
the distribution model in CONTRIBUTING.md: consumers pin a git tag,
and the tag is the contract.

---

## 12. Recurring maintenance

What to do on a quarterly cadence to keep the score stable. Set a
calendar reminder; this is ~30 minutes of work per quarter.

| Cadence | Action | Reference |
|---|---|---|
| Quarterly | Re-run the Scorecard workflow (Actions → scorecard.yml → Run workflow) and check <https://scorecard.dev/viewer/?uri=github.com/ivasik-k7/solidus-finops> | §1 |
| Quarterly | Skim open Dependabot PRs; merge the action-SHA-bump PRs after diff review | §5 |
| Per-PR | Any new `uses:` line in a workflow must be SHA-pinned in the same PR. Reject PRs that introduce tag-only pins. | §5 |
| Quarterly | Verify branch-protection ruleset is still in place: `gh api repos/ivasik-k7/solidus-finops/rulesets`. If empty, rerun `scripts/setup-branch-protection.sh`. | §2 |
| Quarterly | Confirm `Maintained` heuristic is still green by counting commits in the trailing 90 days. If < 3, ship a docs update. | §4 |
| On new contributor | Add to `CONTRIBUTORS.md` and to the relevant `CODEOWNERS` line if appropriate. | §8 |
| On new release | Confirm the attestation step in `release.yml` ran and produced an attestation visible at `gh attestation list --owner ivasik-k7`. | §9 |

The "defensive check" on branch protection is worth calling out
separately: GitHub org-wide admin actions (e.g. an org-level ruleset
applied retroactively, or a manual ruleset deletion) can reset the
repo's protection state without a corresponding repo-level audit
entry. The quarterly check catches that drift.

---

## 13. What we deliberately do NOT do

Documented so a future reviewer does not waste time proposing them.

**We do not require signed commits.** Scorecard's Branch-Protection
check awards partial credit for `required_signatures = true`. We
explicitly leave this off. Rationale:

- It raises the bar for casual contributors (every contributor needs
  GPG / SSH-signing configured locally) without adding meaningful
  audit value beyond what CODEOWNERS + required reviews + a protected
  default branch already give us.
- Consumers of the framework get end-to-end audit via CloudTrail at
  the AWS side (the IaC is applied by an authenticated principal in
  their account, and every API call is logged). The commit-author
  identity is not the relevant trust anchor.
- The CI surface is content-addressed at the SHA level for both the
  source (git) and the actions it runs (SHA-pinned per §5). That is
  the supply-chain control that matters.

**We do not publish to a package registry.** Solidus FinOps is
distributed as a git-tagged Terraform module. Consumers pin a tag and
diff between tags. Publishing to PyPI / npm / etc. would be
distribution theatre — there is nothing to package. See
[CONTRIBUTING.md](../CONTRIBUTING.md) for the distribution model.

**We do not add fuzz targets.** Covered in §6. No executable surface
to fuzz.

**We do not enforce a strict 2-reviewer requirement.** Single-
maintainer project; a 2-reviewer rule would block every PR. When a
co-maintainer joins, raise the requirement on security-sensitive
paths (`**/iam.tf`, `**/kms*.tf`, `/.github/`, `/LICENSE`,
`/SECURITY.md`) to 2 via the CODEOWNERS file. The Branch-Protection
ruleset already supports CODEOWNERS-scoped review counts.

---

## 14. References

- Live score:
  <https://scorecard.dev/viewer/?uri=github.com/ivasik-k7/solidus-finops>
- Scorecard project:
  <https://github.com/ossf/scorecard>
- Per-check definitions:
  <https://github.com/ossf/scorecard/blob/main/docs/checks.md>
- SLSA Level 3 context (for §9):
  <https://slsa.dev/spec/v1.0/levels>
- OpenSSF Best Practices submission (for §7):
  <https://www.bestpractices.dev/en/projects/new>
- `actions/attest-build-provenance`:
  <https://github.com/actions/attest-build-provenance>
- This repo's branch-protection setup script:
  `scripts/setup-branch-protection.sh`
- This repo's CODEOWNERS file: `.github/CODEOWNERS`
- This repo's Dependabot config: `.github/dependabot.yml`
- This repo's release workflow: `.github/workflows/release.yml`
- Related framework docs:
  [THREAT_MODEL.md](THREAT_MODEL.md),
  [COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md),
  [OPERATIONAL_RUNBOOK.md](OPERATIONAL_RUNBOOK.md),
  [CONTRIBUTING.md](../CONTRIBUTING.md).

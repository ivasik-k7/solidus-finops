#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup-branch-protection.sh
# ---------------------------------------------------------------------------
#
# What it does
#   Applies classic branch protection (required reviews, required status
#   checks, linear history, force-push/deletion blocks, conversation-resolution
#   gating, optional signed-commit enforcement) to one OR MORE branches, plus
#   release-tag protection on v*.*.* tags. Owner/name is auto-detected, so it
#   works on any fork without edits. Idempotent: re-running converges state.
#
# !!! READ THIS IF YOUR OPENSSF SCORECARD "Branch-Protection" SCORE IS LOW !!!
#   Scorecard CANNOT read CLASSIC branch protection with the default
#   GITHUB_TOKEN, so it reports "branch protection not enabled" even when this
#   script succeeded. Fix it ONE of two ways:
#     (a) Give the Scorecard workflow a fine-grained PAT with
#         "Administration: Read-only" via `repo_token: ${{ secrets.SCORECARD_TOKEN }}`.
#     (b) Migrate to Repository Rulesets, which Scorecard reads with the
#         default token. (Rulesets also target branch *patterns* natively.)
#   Also note: Scorecard only scores the DEFAULT branch and RELEASE branches.
#   Protecting extra branches below is good hygiene but will not move that score.
#
# OpenSSF Scorecard heuristics addressed
#   - Branch-Protection (HIGH) -- default branch hardened (needs readable token; see above)
#   - Code-Review     (HIGH)   -- required reviews, CODEOWNERS, stale dismiss
#   Indirect uplift to Signed-Releases via tag protection on v*.*.* tags.
#
# Prerequisites
#   - `gh` CLI authenticated with admin rights on the repo (scope: `repo`)
#   - `jq` on PATH
#
# How to run
#   chmod +x scripts/setup-branch-protection.sh   # first time only
#   cd /path/to/repo && bash scripts/setup-branch-protection.sh
# ---------------------------------------------------------------------------

# --- configuration --------------------------------------------------------
# Branches to protect. The default branch matters most (and is the only one
# Scorecard scores). Extra branches are applied only if they exist on this
# repo; missing ones are skipped with a soft warning so the script stays
# fork-safe. Add/remove entries to taste.
BRANCHES=(
  "main"
  # "develop"
  # "staging"
)

# Release-tag protection. The classic /tags/protection REST API was REMOVED by
# GitHub after 2024-08-30, so tags are now protected via a repository RULESET.
# TAG_REF_PATTERN is an fnmatch over the full ref; "refs/tags/v*" covers all
# v-prefixed release tags. RULESET_NAME is the idempotency key (re-runs update
# the existing ruleset instead of creating duplicates).
TAG_REF_PATTERN="refs/tags/v*"
RULESET_NAME="Protect release tags"

# Opt-in: require all commits on protected branches to be signed (GPG/SSH/S-MIME
# verified). Great-to-have, but it WILL block unsigned pushes/merges for every
# contributor, so enable only once your team signs commits. Set to "true" to turn on.
REQUIRE_SIGNED_COMMITS="false"

# Required approving reviews. Bump to 2 if you have >=2 active maintainers;
# Scorecard's top Code-Review tier rewards stricter review.
REQUIRED_APPROVALS="1"

# --- preflight ------------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH"     >&2; exit 1; }

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
if [[ -z "${OWNER_REPO}" ]]; then
  echo "ERROR: failed to auto-detect owner/repo via 'gh repo view'." >&2
  exit 1
fi

echo "==> Target repository : ${OWNER_REPO}"
echo "==> Branches          : ${BRANCHES[*]}"
echo "==> Tag protection    : ${TAG_REF_PATTERN} (ruleset: ${RULESET_NAME})"
echo "==> Signed commits    : ${REQUIRE_SIGNED_COMMITS}"
echo "==> Required approvals : ${REQUIRED_APPROVALS}"
echo

TMP_ERR=$(mktemp)
trap 'rm -f "${TMP_ERR}"' EXIT

# --- required status check contexts ---------------------------------------
# Case-sensitive job-name strings emitted by the CI workflows. If a context
# does not yet exist on the repo, the PUT 422s; we soft-warn and continue.
read -r -d '' CONTEXTS_JSON <<'JSON' || true
[
  "terraform fmt",
  "validate (.)",
  "validate (examples/minimal)",
  "validate (examples/selective)",
  "validate (examples/production)",
  "validate (examples/cloudability-complement)",
  "tflint",
  "checkov",
  "lint-and-typecheck",
  "trivy",
  "gitleaks",
  "codeql"
]
JSON

# --- build the protection payload -----------------------------------------
build_payload() {
  local signed="$1" approvals="$2"
  jq -n \
    --argjson contexts "${CONTEXTS_JSON}" \
    --argjson signed "${signed}" \
    --argjson approvals "${approvals}" '{
    required_status_checks: {
      strict:   true,
      contexts: $contexts
    },
    enforce_admins: true,
    required_pull_request_reviews: {
      required_approving_review_count: $approvals,
      dismiss_stale_reviews:           true,
      require_code_owner_reviews:      true,
      require_last_push_approval:      true
    },
    restrictions:                     null,
    required_linear_history:          true,
    allow_force_pushes:               false,
    allow_deletions:                  false,
    block_creations:                  false,
    required_conversation_resolution: true,
    lock_branch:                      false,
    allow_fork_syncing:               true,
    required_signatures:              $signed
  }'
}

# --- apply protection to a single branch ----------------------------------
apply_branch() {
  local branch="$1"

  # Skip branches that don't exist on this repo (fork-safe).
  if ! gh api "repos/${OWNER_REPO}/branches/${branch}" >/dev/null 2>&1; then
    echo "==> [${branch}] does not exist on ${OWNER_REPO} -- skipping."
    return 0
  fi

  echo "==> [${branch}] applying branch protection..."
  if build_payload "${REQUIRE_SIGNED_COMMITS}" "${REQUIRED_APPROVALS}" \
    | gh api \
        --method PUT \
        -H "Accept: application/vnd.github+json" \
        "repos/${OWNER_REPO}/branches/${branch}/protection" \
        --input - \
        >/dev/null 2>"${TMP_ERR}"; then
    echo "    OK -- protection applied to '${branch}'."
  else
    echo "    WARN -- PUT for '${branch}' returned non-zero. Detail:" >&2
    cat "${TMP_ERR}" >&2
    echo "    Most common cause: a required status check context does not yet" >&2
    echo "    exist (no PR has ever run that workflow on this branch). Re-run" >&2
    echo "    after the first green PR lands on '${branch}'." >&2
  fi
}

# --- read-back a single branch --------------------------------------------
readback_branch() {
  local branch="$1" rb
  if ! rb=$(gh api "repos/${OWNER_REPO}/branches/${branch}/protection" 2>/dev/null); then
    echo "    [${branch}] no readable protection (PUT failed or token lacks admin read)." >&2
    return 0
  fi
  echo "==> Read-back: ${OWNER_REPO}@${branch}"
  printf "    %-38s %s\n" "required_status_checks.strict"    "$(echo "${rb}" | jq -r '.required_status_checks.strict // false')"
  printf "    %-38s %s\n" "status_checks.contexts (count)"   "$(echo "${rb}" | jq -r '.required_status_checks.contexts | length')"
  printf "    %-38s %s\n" "enforce_admins.enabled"           "$(echo "${rb}" | jq -r '.enforce_admins.enabled // false')"
  printf "    %-38s %s\n" "required_approving_review_count"  "$(echo "${rb}" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')"
  printf "    %-38s %s\n" "dismiss_stale_reviews"            "$(echo "${rb}" | jq -r '.required_pull_request_reviews.dismiss_stale_reviews // false')"
  printf "    %-38s %s\n" "require_code_owner_reviews"       "$(echo "${rb}" | jq -r '.required_pull_request_reviews.require_code_owner_reviews // false')"
  printf "    %-38s %s\n" "require_last_push_approval"       "$(echo "${rb}" | jq -r '.required_pull_request_reviews.require_last_push_approval // false')"
  printf "    %-38s %s\n" "required_linear_history"          "$(echo "${rb}" | jq -r '.required_linear_history.enabled // false')"
  printf "    %-38s %s\n" "allow_force_pushes"               "$(echo "${rb}" | jq -r '.allow_force_pushes.enabled // false')"
  printf "    %-38s %s\n" "allow_deletions"                  "$(echo "${rb}" | jq -r '.allow_deletions.enabled // false')"
  printf "    %-38s %s\n" "required_conversation_resolution" "$(echo "${rb}" | jq -r '.required_conversation_resolution.enabled // false')"
  printf "    %-38s %s\n" "required_signatures"              "$(echo "${rb}" | jq -r '.required_signatures.enabled // false')"
  echo
}

# --- apply to all configured branches -------------------------------------
for b in "${BRANCHES[@]}"; do
  apply_branch "${b}"
  echo
done

# --- tag protection via repository ruleset --------------------------------
# Locks v* tags so they cannot be deleted or rewritten (non-fast-forward)
# after publication. Idempotent: looks up a ruleset by name and PUTs an update
# if it exists, otherwise POSTs a new one. No bypass_actors => applies to
# everyone including admins (matching the original "nobody can rewrite" intent;
# add a bypass actor if you need an escape hatch).
echo "==> Applying tag protection ruleset '${RULESET_NAME}' (${TAG_REF_PATTERN})..."
RULESET_PAYLOAD=$(jq -n --arg name "${RULESET_NAME}" --arg ref "${TAG_REF_PATTERN}" '{
  name:        $name,
  target:      "tag",
  enforcement: "active",
  conditions:  { ref_name: { include: [ $ref ], exclude: [] } },
  rules: [
    { type: "deletion" },
    { type: "non_fast_forward" }
  ],
  bypass_actors: []
}')

EXISTING_RULESET_ID=$(RNAME="${RULESET_NAME}" \
  gh api "repos/${OWNER_REPO}/rulesets" \
    --jq '.[] | select(.name == env.RNAME) | .id' 2>/dev/null | head -n1 || true)

if [[ -n "${EXISTING_RULESET_ID}" ]]; then
  if printf '%s' "${RULESET_PAYLOAD}" \
    | gh api --method PUT -H "Accept: application/vnd.github+json" \
        "repos/${OWNER_REPO}/rulesets/${EXISTING_RULESET_ID}" --input - \
        >/dev/null 2>"${TMP_ERR}"; then
    echo "    OK -- updated existing ruleset (id=${EXISTING_RULESET_ID})."
  else
    echo "    WARN -- failed to update ruleset. Detail:" >&2
    cat "${TMP_ERR}" >&2
  fi
else
  if printf '%s' "${RULESET_PAYLOAD}" \
    | gh api --method POST -H "Accept: application/vnd.github+json" \
        "repos/${OWNER_REPO}/rulesets" --input - \
        >/dev/null 2>"${TMP_ERR}"; then
    echo "    OK -- tag protection ruleset created."
  else
    echo "    WARN -- failed to create ruleset. Detail:" >&2
    cat "${TMP_ERR}" >&2
  fi
fi
echo

# --- read-back summary ----------------------------------------------------
echo "==> Read-back summary (source of truth: GitHub API)"
echo
for b in "${BRANCHES[@]}"; do
  readback_branch "${b}"
done

echo "==> Tag protection rulesets:"
gh api "repos/${OWNER_REPO}/rulesets" \
  --jq '.[] | select(.target == "tag") | "    - \(.name)  (id=\(.id), \(.enforcement))"' \
  2>/dev/null || echo "    (none)"

echo
echo "==> Done. Re-run any time to reconverge to desired state."
echo "    Reminder: if Scorecard still warns, the fix is the readable token /"
echo "    ruleset migration described in the header, NOT more branches."
exit 0
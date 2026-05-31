#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup-branch-protection.sh
# ---------------------------------------------------------------------------
#
# What it does
#   Configures branch protection, required pull-request reviews, required
#   status checks, linear-history enforcement, force-push/deletion blocks,
#   conversation-resolution gating, and release-tag protection on the
#   GitHub repository this script is run against. The repo owner/name is
#   auto-detected from `gh repo view`, so the script works against any fork
#   of solidus-finops without edits. The script is idempotent: re-running it
#   converges the repo to the same desired state.
#
# OpenSSF Scorecard heuristics addressed
#   - Branch-Protection (HIGH)  -- main branch hardened end-to-end
#   - Code-Review     (HIGH)    -- required reviews, CODEOWNERS, stale dismiss
#   Indirect uplift to Signed-Releases via tag protection on v*.*.* tags.
#
# Prerequisites
#   - `gh` CLI installed and on PATH (https://cli.github.com/)
#   - `gh auth status` reports a logged-in user with admin rights on the repo
#   - GitHub OAuth scopes required: `repo` (covers private repo settings,
#     branch protection, and tag protection administration)
#   - `jq` on PATH (used to pretty-print the read-back summary)
#
# How to run
#   chmod +x scripts/setup-branch-protection.sh   # first time only
#   cd /path/to/repo && bash scripts/setup-branch-protection.sh
#
# How to verify (independent read-back)
#   gh api "repos/:owner/:repo/branches/main/protection" | jq .
#   gh api "repos/:owner/:repo/tags/protection"          | jq .
#
# Exit codes
#   0  success (idempotent re-runs always exit 0)
#   1  any failure (auth, missing tools, API rejection, etc.)
# ---------------------------------------------------------------------------

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

BRANCH="main"
TAG_PATTERN="v*.*.*"

echo "==> Target repository : ${OWNER_REPO}"
echo "==> Target branch     : ${BRANCH}"
echo "==> Tag protection    : ${TAG_PATTERN}"
echo

# --- required status check contexts ---------------------------------------
# Case-sensitive job-name strings emitted by:
#   .github/workflows/terraform-ci.yml
#   .github/workflows/python-ci.yml
#   .github/workflows/security.yml
# If a context does not yet exist on the repo, GitHub returns 422; we treat
# that as a soft warning and continue so first-run on a fresh fork still
# applies the rest of the policy.
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

# --- branch protection payload --------------------------------------------
PROTECTION_PAYLOAD=$(jq -n --argjson contexts "${CONTEXTS_JSON}" '{
  required_status_checks: {
    strict:   true,
    contexts: $contexts
  },
  enforce_admins: true,
  required_pull_request_reviews: {
    required_approving_review_count: 1,
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
  required_signatures:              false
}')

# --- apply branch protection ----------------------------------------------
echo "==> Applying branch protection to '${BRANCH}'..."
TMP_ERR=$(mktemp)
trap 'rm -f "${TMP_ERR}"' EXIT

if printf '%s' "${PROTECTION_PAYLOAD}" \
  | gh api \
      --method PUT \
      -H "Accept: application/vnd.github+json" \
      "repos/${OWNER_REPO}/branches/${BRANCH}/protection" \
      --input - \
      >/dev/null 2>"${TMP_ERR}"; then
  echo "    OK -- branch protection applied."
else
  echo "    WARN -- PUT returned non-zero. Detail:" >&2
  cat "${TMP_ERR}" >&2
  echo "    Most common cause: a required status check context does not yet" >&2
  echo "    exist on this repo (no PR has ever run that workflow). Re-run" >&2
  echo "    this script after the first green PR lands on '${BRANCH}'."    >&2
  # We intentionally do NOT exit here so tag protection still gets applied.
fi
echo

# --- apply tag protection for release tags --------------------------------
# Locks v*.*.* tags so nobody (including admins) can delete or rewrite them
# after publication. Idempotent: GitHub returns 422 if the same pattern is
# already registered; we swallow that case.
echo "==> Applying tag protection for pattern '${TAG_PATTERN}'..."
TAG_PAYLOAD=$(jq -n --arg pattern "${TAG_PATTERN}" '{pattern: $pattern}')

EXISTING_TAG_PATTERNS=$(gh api "repos/${OWNER_REPO}/tags/protection" --jq '.[].pattern' 2>/dev/null || true)
if echo "${EXISTING_TAG_PATTERNS}" | grep -Fxq "${TAG_PATTERN}"; then
  echo "    OK -- tag pattern already protected (idempotent no-op)."
else
  if printf '%s' "${TAG_PAYLOAD}" \
    | gh api \
        --method POST \
        -H "Accept: application/vnd.github+json" \
        "repos/${OWNER_REPO}/tags/protection" \
        --input - \
        >/dev/null 2>"${TMP_ERR}"; then
    echo "    OK -- tag protection rule created."
  else
    echo "    WARN -- failed to create tag protection rule. Detail:" >&2
    cat "${TMP_ERR}" >&2
  fi
fi
echo

# --- read-back summary ----------------------------------------------------
echo "==> Read-back summary for ${OWNER_REPO}@${BRANCH}"
echo "    (source of truth: GitHub API, not local payload)"
echo

if ! READBACK=$(gh api "repos/${OWNER_REPO}/branches/${BRANCH}/protection" 2>/dev/null); then
  echo "ERROR: failed to read back branch protection. The PUT above likely failed." >&2
  exit 1
fi

printf "%-42s %s\n" "Setting" "Value"
printf "%-42s %s\n" "------------------------------------------" "------------------------------"
printf "%-42s %s\n" "required_status_checks.strict"             "$(echo "${READBACK}" | jq -r '.required_status_checks.strict // false')"
printf "%-42s %s\n" "required_status_checks.contexts (count)"   "$(echo "${READBACK}" | jq -r '.required_status_checks.contexts | length')"
printf "%-42s %s\n" "enforce_admins.enabled"                    "$(echo "${READBACK}" | jq -r '.enforce_admins.enabled // false')"
printf "%-42s %s\n" "required_approving_review_count"           "$(echo "${READBACK}" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')"
printf "%-42s %s\n" "dismiss_stale_reviews"                     "$(echo "${READBACK}" | jq -r '.required_pull_request_reviews.dismiss_stale_reviews // false')"
printf "%-42s %s\n" "require_code_owner_reviews"                "$(echo "${READBACK}" | jq -r '.required_pull_request_reviews.require_code_owner_reviews // false')"
printf "%-42s %s\n" "require_last_push_approval"                "$(echo "${READBACK}" | jq -r '.required_pull_request_reviews.require_last_push_approval // false')"
printf "%-42s %s\n" "required_linear_history"                   "$(echo "${READBACK}" | jq -r '.required_linear_history.enabled // false')"
printf "%-42s %s\n" "allow_force_pushes"                        "$(echo "${READBACK}" | jq -r '.allow_force_pushes.enabled // false')"
printf "%-42s %s\n" "allow_deletions"                           "$(echo "${READBACK}" | jq -r '.allow_deletions.enabled // false')"
printf "%-42s %s\n" "block_creations"                           "$(echo "${READBACK}" | jq -r '.block_creations.enabled // false')"
printf "%-42s %s\n" "required_conversation_resolution"          "$(echo "${READBACK}" | jq -r '.required_conversation_resolution.enabled // false')"
printf "%-42s %s\n" "lock_branch"                               "$(echo "${READBACK}" | jq -r '.lock_branch.enabled // false')"
printf "%-42s %s\n" "allow_fork_syncing"                        "$(echo "${READBACK}" | jq -r '.allow_fork_syncing.enabled // false')"
printf "%-42s %s\n" "required_signatures"                       "$(echo "${READBACK}" | jq -r '.required_signatures.enabled // false')"

echo
echo "==> Required status check contexts currently enforced:"
echo "${READBACK}" | jq -r '.required_status_checks.contexts[]? | "    - \(.)"'

echo
echo "==> Tag protection rules:"
gh api "repos/${OWNER_REPO}/tags/protection" --jq '.[] | "    - pattern=\(.pattern)  id=\(.id)"' 2>/dev/null || echo "    (none)"

echo
echo "==> Done. Re-run this script any time to reconverge to desired state."
exit 0

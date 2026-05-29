#!/usr/bin/env bash
#
# emergency-start-all.sh
# ----------------------
# Force-start every resource the scheduler is currently managing. Use only
# when the scheduler is broken, paused, or otherwise unable to act, and you
# need every managed resource running RIGHT NOW (incident, sales demo,
# disaster recovery).
#
# Reads the scheduler's DynamoDB STATE rows, fires the appropriate AWS API
# call per resource. Does NOT clear FinOpsException or ScheduleOverrideUntil
# tags — exempt resources stay exempt.
#
# Idempotent: re-running is safe. AWS rejects start-on-running with
# AlreadyExists or similar; the script counts those as no-ops.
#
# Required env:
#   STATE_TABLE     scheduler-state DDB table name (output: state_table_name)
#   AWS_REGION      home region the table lives in
#
# Optional env:
#   DRY_RUN=true    log what would happen, don't act
#   FILTER_REGION   only act on resources in this region (default: all)
#   PARALLEL=8      max concurrent start calls (default 8)
#
# Usage:
#   STATE_TABLE=finops-prod-scheduler-state AWS_REGION=eu-central-1 \
#     ./emergency-start-all.sh
#
#   STATE_TABLE=... AWS_REGION=... DRY_RUN=true ./emergency-start-all.sh
#

set -euo pipefail

: "${STATE_TABLE:?STATE_TABLE env var required (DDB table name)}"
: "${AWS_REGION:?AWS_REGION env var required (home region of the table)}"
: "${PARALLEL:=8}"
DRY_RUN=${DRY_RUN:-false}
FILTER_REGION=${FILTER_REGION:-}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf "[%s] %s\n" "$(ts)" "$*" >&2; }

log "Querying ${STATE_TABLE} in ${AWS_REGION}..."
log "DRY_RUN=${DRY_RUN}  FILTER_REGION=${FILTER_REGION:-<all>}  PARALLEL=${PARALLEL}"

# Stream every STATE row out as TSV: ResourceType<TAB>ResourceId<TAB>Region
state_rows() {
  aws dynamodb scan \
    --table-name "${STATE_TABLE}" \
    --region "${AWS_REGION}" \
    --filter-expression "SK = :sk" \
    --expression-attribute-values '{":sk":{"S":"STATE"}}' \
    --projection-expression "ResourceType,ResourceId,#r" \
    --expression-attribute-names '{"#r":"Region"}' \
    --output json \
  | jq -r '.Items[] | [.ResourceType.S, .ResourceId.S, .Region.S] | @tsv'
}

start_one() {
  local rtype="$1" rid="$2" region="$3"
  if [[ -n "${FILTER_REGION}" && "${region}" != "${FILTER_REGION}" ]]; then
    return 0
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY_RUN: would start ${rtype} ${rid} in ${region}"
    return 0
  fi
  case "${rtype}" in
    EC2)
      aws ec2 start-instances --instance-ids "${rid}" --region "${region}" \
        >/dev/null 2>&1 && log "started EC2 ${rid} (${region})" \
        || log "SKIPPED EC2 ${rid} (${region}) — already running or stop-protected"
      ;;
    RDSInstance)
      aws rds start-db-instance --db-instance-identifier "${rid}" --region "${region}" \
        >/dev/null 2>&1 && log "started RDSInstance ${rid} (${region})" \
        || log "SKIPPED RDSInstance ${rid} (${region}) — already running or transient state"
      ;;
    RDSCluster)
      aws rds start-db-cluster --db-cluster-identifier "${rid}" --region "${region}" \
        >/dev/null 2>&1 && log "started RDSCluster ${rid} (${region})" \
        || log "SKIPPED RDSCluster ${rid} (${region}) — already running or transient state"
      ;;
    ASG)
      # Restore saved capacity from tags; default to 1/1 if missing.
      local saved_min saved_desired
      saved_min=$(aws autoscaling describe-tags \
        --filters "Name=auto-scaling-group,Values=${rid}" "Name=key,Values=FinOpsSavedMin" \
        --region "${region}" --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
      saved_desired=$(aws autoscaling describe-tags \
        --filters "Name=auto-scaling-group,Values=${rid}" "Name=key,Values=FinOpsSavedDesired" \
        --region "${region}" --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
      [[ "${saved_min}" == "None" || -z "${saved_min}" ]] && saved_min=1
      [[ "${saved_desired}" == "None" || -z "${saved_desired}" ]] && saved_desired=1
      aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "${rid}" \
        --min-size "${saved_min}" --desired-capacity "${saved_desired}" \
        --region "${region}" \
        && log "scaled ASG ${rid} to min=${saved_min}/desired=${saved_desired} (${region})" \
        || log "FAILED ASG ${rid} (${region})"
      ;;
    *)
      log "UNKNOWN resource type ${rtype} for ${rid} — skipping"
      ;;
  esac
}

export -f start_one ts log
export DRY_RUN FILTER_REGION

count=0
state_rows | while IFS=$'\t' read -r rtype rid region; do
  count=$((count+1))
  # Bounded parallelism via xargs would be cleaner; bash inline kept simple.
  start_one "${rtype}" "${rid}" "${region}" &
  if (( count % PARALLEL == 0 )); then
    wait
  fi
done
wait
log "done."

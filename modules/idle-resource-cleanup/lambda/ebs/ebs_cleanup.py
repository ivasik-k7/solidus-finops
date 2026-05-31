"""
Idle EBS volume detector with two-phase deletion, multi-region scanning,
and DynamoDB-backed lifecycle state.

Phase 1: detect idle volumes, snapshot, tag FinOpsPendingDeletion=<snap>.
Phase 2: any run where the snapshot is `completed` and the grace period
elapsed, delete the volume.

State tracking via idle_state (shared helper):
  - Each STATE row dedups findings across weekly runs.
  - SeenCount escalates severity automatically (aging detection).
  - is_actionable() honors snooze + exception lifecycle states.
  - Every mutation appends an ACTION row → audit trail + cumulative savings.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
from typing import Any

import boto3
from botocore.config import Config

import idle_state

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"
MIN_AGE_DAYS = int(os.environ.get("MIN_AGE_DAYS", "14"))
EXCEPTION_TAG_KEY = os.environ.get("EXCEPTION_TAG_KEY", "FinOpsException")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FinOps/IdleResources")
COST_CEILING_USD = float(os.environ.get("COST_CEILING_USD", "10000"))
PENDING_GRACE_HOURS = int(os.environ.get("PENDING_GRACE_HOURS", "24"))
PENDING_GRACE_MAX_HOURS = int(os.environ.get("PENDING_GRACE_MAX_HOURS", "168"))
SCAN_REGIONS: list[str] = json.loads(os.environ.get("SCAN_REGIONS", "[]"))

PENDING_TAG_KEY = "FinOpsPendingDeletion"
PENDING_SINCE_TAG_KEY = "FinOpsPendingSince"

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
sns = boto3.client("sns", config=_boto)
cw = boto3.client("cloudwatch", config=_boto)
sts = boto3.client("sts")

_ACCOUNT_ID = sts.get_caller_identity()["Account"]
_ACTOR_ID = f"lambda:{os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}"


def handler(event, context):
    logger.info(
        "EBS idle scan: dry_run=%s min_age=%sd ceiling=$%s regions=%s",
        DRY_RUN,
        MIN_AGE_DAYS,
        COST_CEILING_USD,
        SCAN_REGIONS or "[home]",
    )

    all_p1: list[dict] = []
    all_p2: list[dict] = []
    errors: list[dict] = []
    cumulative_savings = 0.0
    cumulative_phase1_usd = 0.0
    ceiling_hit = False

    for region in SCAN_REGIONS or [None]:
        ec2 = boto3.client("ec2", region_name=region, config=_boto)
        eff_region = region or ec2.meta.region_name

        try:
            for page in ec2.get_paginator("describe_volumes").paginate(
                Filters=[{"Name": "tag-key", "Values": [PENDING_TAG_KEY]}],
            ):
                for vol in page["Volumes"]:
                    try:
                        outcome = _phase2_finalize(ec2, eff_region, vol)
                        if outcome:
                            all_p2.append(outcome)
                            if outcome.get("Outcome") == "deleted":
                                cumulative_savings += outcome.get("SavedUsd", 0.0)
                    except Exception as e:
                        logger.exception(
                            "Phase 2 failed for %s in %s",
                            vol.get("VolumeId"),
                            eff_region,
                        )
                        errors.append(
                            {
                                "region": eff_region,
                                "phase": 2,
                                "volume_id": vol.get("VolumeId"),
                                "error": str(e),
                            }
                        )
        except Exception as e:
            logger.exception("Phase 2 list failed in %s", eff_region)
            errors.append({"region": eff_region, "phase": 2, "error": str(e)})

        try:
            for page in ec2.get_paginator("describe_volumes").paginate(
                Filters=[{"Name": "status", "Values": ["available"]}],
            ):
                for vol in page["Volumes"]:
                    try:
                        outcome = _phase1_detect(
                            ec2, eff_region, vol, cumulative_phase1_usd
                        )
                        if outcome.get("ceiling_hit"):
                            ceiling_hit = True
                        if outcome.get("finding"):
                            all_p1.append(outcome["finding"])
                            cumulative_phase1_usd += outcome["finding"][
                                "EstimatedMonthlyCostUsd"
                            ]
                    except Exception as e:
                        logger.exception(
                            "Phase 1 failed for %s in %s",
                            vol.get("VolumeId"),
                            eff_region,
                        )
                        errors.append(
                            {
                                "region": eff_region,
                                "phase": 1,
                                "volume_id": vol.get("VolumeId"),
                                "error": str(e),
                            }
                        )
        except Exception as e:
            logger.exception("Phase 1 list failed in %s", eff_region)
            errors.append({"region": eff_region, "phase": 1, "error": str(e)})

    total_waste = round(sum(f["EstimatedMonthlyCostUsd"] for f in all_p1), 2)
    aging_count = sum(1 for f in all_p1 if f.get("IsAging"))
    summary = {
        "AlertName": "Idle EBS volume scan",
        "severity": _severity(all_p1, aging_count),
        "DryRun": DRY_RUN,
        "MinAgeDays": MIN_AGE_DAYS,
        "Regions": SCAN_REGIONS or ["home"],
        "CostCeilingUsd": COST_CEILING_USD,
        "CostCeilingReached": ceiling_hit,
        "Phase1FoundCount": len(all_p1),
        "Phase1MonthlyWasteUsd": total_waste,
        "Phase1AgingCount": aging_count,
        "Phase2ActionsCount": len(all_p2),
        "RunSavingsUsd": round(cumulative_savings, 2),
        "ErrorCount": len(errors),
        "Phase1Findings": all_p1[:50],
        "Phase1Truncated": len(all_p1) > 50,
        "Phase2Actions": all_p2[:50],
    }
    if errors:
        summary["Errors"] = errors[:20]

    logger.info(json.dumps(summary, default=str))
    _publish_metrics(total_waste, len(all_p1), len(all_p2), cumulative_savings)
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: Idle EBS volume scan",
        Message=json.dumps(summary, default=str, indent=2),
    )
    return summary


def _phase1_detect(ec2, region: str, vol: dict, cumulative_usd: float) -> dict:
    vol_id = vol["VolumeId"]
    create_time = vol["CreateTime"]
    age_days = (dt.datetime.now(create_time.tzinfo) - create_time).days
    tags = {t["Key"]: t["Value"] for t in vol.get("Tags", [])}

    if PENDING_TAG_KEY in tags or EXCEPTION_TAG_KEY in tags or age_days < MIN_AGE_DAYS:
        return {}

    estimated = _estimate_monthly_cost(vol)
    owner = tags.get("Owner") or "(no Owner tag)"

    state = idle_state.upsert_state(
        resource_type="EBS",
        resource_id=vol_id,
        region=region,
        account_id=_ACCOUNT_ID,
        estimated_monthly_cost_usd=estimated,
        owner=owner,
        tags=tags,
        resource_attrs={"SizeGiB": vol["Size"], "VolumeType": vol["VolumeType"]},
    )

    if not idle_state.is_actionable(state):
        logger.info("Skipping %s (status=%s)", vol_id, state.get("Status"))
        return {}

    finding: dict[str, Any] = {
        "VolumeId": vol_id,
        "Region": region,
        "SizeGiB": vol["Size"],
        "VolumeType": vol["VolumeType"],
        "CreateTime": create_time.isoformat(),
        "AgeDays": age_days,
        "EstimatedMonthlyCostUsd": estimated,
        "Owner": owner,
        "Tags": tags,
        "SeenCount": state["SeenCount"],
        "Status": state["Status"],
        "IsAging": state["IsAging"],
    }

    if state["IsNew"]:
        idle_state.record_action(
            resource_type="EBS",
            resource_id=vol_id,
            region=region,
            account_id=_ACCOUNT_ID,
            action_type="detected",
            actor_id=_ACTOR_ID,
            notes=f"AgeDays={age_days}",
        )

    if DRY_RUN:
        return {"finding": finding}

    if cumulative_usd + estimated > COST_CEILING_USD:
        logger.warning("Cost ceiling reached — skipping snapshot for %s", vol_id)
        idle_state.record_action(
            resource_type="EBS",
            resource_id=vol_id,
            region=region,
            account_id=_ACCOUNT_ID,
            action_type="skipped-ceiling",
            actor_id=_ACTOR_ID,
        )
        return {"finding": finding, "ceiling_hit": True}

    snap = ec2.create_snapshot(
        VolumeId=vol_id,
        Description=f"FinOps idle-cleanup retention snapshot for {vol_id}",
        TagSpecifications=[
            {
                "ResourceType": "snapshot",
                "Tags": [
                    {"Key": "FinOpsRetainedFor", "Value": "audit"},
                    {"Key": "FinOpsSnapshotReason", "Value": "idle-cleanup"},
                    {"Key": "FinOpsSourceVolume", "Value": vol_id},
                    {"Key": EXCEPTION_TAG_KEY, "Value": "true"},
                ],
            }
        ],
    )
    snap_id = snap["SnapshotId"]
    now_iso = dt.datetime.now(dt.timezone.utc).isoformat()

    ec2.create_tags(
        Resources=[vol_id],
        Tags=[
            {"Key": PENDING_TAG_KEY, "Value": snap_id},
            {"Key": PENDING_SINCE_TAG_KEY, "Value": now_iso},
        ],
    )
    idle_state.record_action(
        resource_type="EBS",
        resource_id=vol_id,
        region=region,
        account_id=_ACCOUNT_ID,
        action_type="snapshotted",
        actor_id=_ACTOR_ID,
        notes=f"snapshot={snap_id}",
    )
    logger.info("Phase 1: tagged %s for deferred deletion (snap %s)", vol_id, snap_id)
    finding["RetentionSnapshotId"] = snap_id
    finding["PendingSince"] = now_iso
    return {"finding": finding}


def _phase2_finalize(ec2, region: str, vol: dict) -> dict | None:
    vol_id = vol["VolumeId"]
    tags = {t["Key"]: t["Value"] for t in vol.get("Tags", [])}
    snap_id = tags.get(PENDING_TAG_KEY)
    pending_since_raw = tags.get(PENDING_SINCE_TAG_KEY)
    if not snap_id or not pending_since_raw:
        return None

    try:
        pending_since = dt.datetime.fromisoformat(pending_since_raw)
    except ValueError:
        return None
    hours_pending = (
        dt.datetime.now(pending_since.tzinfo) - pending_since
    ).total_seconds() / 3600.0

    snap_info = ec2.describe_snapshots(SnapshotIds=[snap_id]).get("Snapshots", [])
    snap_state = snap_info[0]["State"] if snap_info else "missing"
    estimated = _estimate_monthly_cost(vol)
    action: dict[str, Any] = {
        "VolumeId": vol_id,
        "Region": region,
        "SnapshotId": snap_id,
        "SnapshotState": snap_state,
        "HoursPending": round(hours_pending, 1),
        "EstimatedMonthlyCostUsd": estimated,
    }

    if snap_state == "completed" and hours_pending >= PENDING_GRACE_HOURS:
        if DRY_RUN:
            action["Outcome"] = "would-delete-volume"
            return action
        ec2.delete_volume(VolumeId=vol_id)
        idle_state.record_action(
            resource_type="EBS",
            resource_id=vol_id,
            region=region,
            account_id=_ACCOUNT_ID,
            action_type="deleted",
            actor_id=_ACTOR_ID,
            estimated_savings_usd=estimated,
            notes=f"snapshot={snap_id}",
        )
        action["Outcome"] = "deleted"
        action["SavedUsd"] = estimated
        return action

    if hours_pending > PENDING_GRACE_MAX_HOURS or snap_state in ("error", "missing"):
        action["Outcome"] = f"rollback-{snap_state}"
        logger.error(
            "Phase 2 rollback for %s — snap=%s hours=%s",
            vol_id,
            snap_state,
            round(hours_pending, 1),
        )
        if not DRY_RUN:
            ec2.delete_tags(
                Resources=[vol_id],
                Tags=[{"Key": PENDING_TAG_KEY}, {"Key": PENDING_SINCE_TAG_KEY}],
            )
            idle_state.record_action(
                resource_type="EBS",
                resource_id=vol_id,
                region=region,
                account_id=_ACCOUNT_ID,
                action_type="rollback",
                actor_id=_ACTOR_ID,
                notes=f"snap_state={snap_state}",
            )
        return action

    action["Outcome"] = "still-pending"
    return action


def _severity(findings, aging_count):
    if not findings:
        return "low"
    total = sum(f["EstimatedMonthlyCostUsd"] for f in findings)
    if total > 500 or aging_count > 0:
        return "high"
    if total > 100:
        return "medium"
    return "low"


def _publish_metrics(monthly_waste, found, actions, savings):
    dim = [{"Name": "ResourceType", "Value": "EBS"}]
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": "MonthlyWasteUsd",
                "Value": float(monthly_waste),
                "Unit": "None",
                "Dimensions": dim,
            },
            {
                "MetricName": "FoundCount",
                "Value": float(found),
                "Unit": "Count",
                "Dimensions": dim,
            },
            {
                "MetricName": "ActionsTakenCount",
                "Value": float(actions),
                "Unit": "Count",
                "Dimensions": dim,
            },
            {
                "MetricName": "RunSavingsUsd",
                "Value": float(savings),
                "Unit": "None",
                "Dimensions": dim,
            },
        ],
    )


def _estimate_monthly_cost(vol):
    size = vol["Size"]
    vol_type = vol["VolumeType"]
    rates = {
        "gp3": 0.08,
        "gp2": 0.10,
        "io1": 0.125,
        "io2": 0.125,
        "st1": 0.045,
        "sc1": 0.025,
        "standard": 0.05,
    }
    return round(size * rates.get(vol_type, 0.10), 2)

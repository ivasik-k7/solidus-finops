"""
Old / orphaned EBS snapshot detector with multi-region scanning and
DDB-backed state lifecycle.

Skips AMI-backed snapshots, exception-tagged snapshots, and anything
younger than MIN_AGE_DAYS. Every deletion is logged to the audit trail
with the estimated $ saved.
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
MIN_AGE_DAYS = int(os.environ.get("MIN_AGE_DAYS", "90"))
EXCEPTION_TAG_KEY = os.environ.get("EXCEPTION_TAG_KEY", "FinOpsException")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FinOps/IdleResources")
COST_CEILING_USD = float(os.environ.get("COST_CEILING_USD", "10000"))
SNAPSHOT_GB_MONTH_USD = float(os.environ.get("SNAPSHOT_GB_MONTH_USD", "0.05"))
SCAN_REGIONS: list[str] = json.loads(os.environ.get("SCAN_REGIONS", "[]"))

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
sns = boto3.client("sns", config=_boto)
cw = boto3.client("cloudwatch", config=_boto)
sts = boto3.client("sts")

_ACCOUNT_ID = sts.get_caller_identity()["Account"]
_ACTOR_ID = f"lambda:{os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}"


def handler(event, context):
    logger.info(
        "Snapshot scan: dry_run=%s min_age=%sd regions=%s",
        DRY_RUN,
        MIN_AGE_DAYS,
        SCAN_REGIONS or "[home]",
    )

    findings: list[dict] = []
    deleted: list[str] = []
    errors: list[dict] = []
    cumulative_usd = 0.0
    cumulative_savings = 0.0
    ceiling_hit = False

    for region in SCAN_REGIONS or [None]:
        ec2 = boto3.client("ec2", region_name=region, config=_boto)
        eff_region = region or ec2.meta.region_name

        try:
            ami_snapshots = _collect_ami_snapshots(ec2)
        except Exception as e:
            logger.exception("AMI snapshot list failed in %s", eff_region)
            errors.append({"region": eff_region, "phase": "ami-list", "error": str(e)})
            ami_snapshots = set()

        try:
            for page in ec2.get_paginator("describe_snapshots").paginate(
                OwnerIds=["self"]
            ):
                for snap in page["Snapshots"]:
                    try:
                        outcome = _process(
                            ec2, eff_region, snap, ami_snapshots, cumulative_usd
                        )
                        if outcome.get("ceiling_hit"):
                            ceiling_hit = True
                        if outcome.get("finding"):
                            findings.append(outcome["finding"])
                            cumulative_usd += outcome["finding"][
                                "EstimatedMonthlyCostUsd"
                            ]
                        if outcome.get("deleted"):
                            deleted.append(outcome["deleted"])
                            cumulative_savings += outcome["finding"][
                                "EstimatedMonthlyCostUsd"
                            ]
                    except Exception as e:
                        logger.exception("Failed processing %s", snap.get("SnapshotId"))
                        errors.append(
                            {
                                "region": eff_region,
                                "snapshot_id": snap.get("SnapshotId"),
                                "error": str(e),
                            }
                        )
        except Exception as e:
            logger.exception("Snapshot list failed in %s", eff_region)
            errors.append({"region": eff_region, "phase": "list", "error": str(e)})

    total_waste = round(sum(f["EstimatedMonthlyCostUsd"] for f in findings), 2)
    aging_count = sum(1 for f in findings if f.get("IsAging"))
    summary = {
        "AlertName": "Orphan EBS snapshot scan",
        "severity": _severity(total_waste, aging_count),
        "DryRun": DRY_RUN,
        "MinAgeDays": MIN_AGE_DAYS,
        "Regions": SCAN_REGIONS or ["home"],
        "CostCeilingUsd": COST_CEILING_USD,
        "CostCeilingReached": ceiling_hit,
        "FoundCount": len(findings),
        "MonthlyWasteUsd": total_waste,
        "DeletedCount": len(deleted),
        "AgingCount": aging_count,
        "RunSavingsUsd": round(cumulative_savings, 2),
        "ErrorCount": len(errors),
        "Findings": findings[:50],
        "Truncated": len(findings) > 50,
    }
    if errors:
        summary["Errors"] = errors[:20]

    logger.info(json.dumps(summary, default=str))
    _publish_metrics(total_waste, len(findings), len(deleted), cumulative_savings)
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: Orphan snapshot scan",
        Message=json.dumps(summary, default=str, indent=2),
    )
    return summary


def _collect_ami_snapshots(ec2):
    snapshot_ids: set[str] = set()
    for page in ec2.get_paginator("describe_images").paginate(Owners=["self"]):
        for image in page["Images"]:
            for bdm in image.get("BlockDeviceMappings", []):
                snap_id = (bdm.get("Ebs") or {}).get("SnapshotId")
                if snap_id:
                    snapshot_ids.add(snap_id)
    return snapshot_ids


def _process(
    ec2, region: str, snap: dict, ami_snapshots: set, cumulative_usd: float
) -> dict:
    snap_id = snap["SnapshotId"]
    start = snap["StartTime"]
    age_days = (dt.datetime.now(start.tzinfo) - start).days
    tags = {t["Key"]: t["Value"] for t in snap.get("Tags", [])}

    if snap_id in ami_snapshots or EXCEPTION_TAG_KEY in tags or age_days < MIN_AGE_DAYS:
        return {"finding": None}

    estimated = round(snap.get("VolumeSize", 0) * SNAPSHOT_GB_MONTH_USD, 2)
    owner = tags.get("Owner") or "(no Owner tag)"

    state = idle_state.upsert_state(
        resource_type="EBSSnapshot",
        resource_id=snap_id,
        region=region,
        account_id=_ACCOUNT_ID,
        estimated_monthly_cost_usd=estimated,
        owner=owner,
        tags=tags,
        resource_attrs={
            "VolumeSizeGiB": snap.get("VolumeSize"),
            "Description": snap.get("Description", "")[:200],
        },
    )

    if not idle_state.is_actionable(state):
        return {"finding": None}

    finding: dict[str, Any] = {
        "SnapshotId": snap_id,
        "Region": region,
        "VolumeSizeGiB": snap.get("VolumeSize"),
        "StartTime": start.isoformat(),
        "AgeDays": age_days,
        "Description": snap.get("Description", "")[:200],
        "EstimatedMonthlyCostUsd": estimated,
        "Owner": owner,
        "Tags": tags,
        "SeenCount": state["SeenCount"],
        "Status": state["Status"],
        "IsAging": state["IsAging"],
    }

    if state["IsNew"]:
        idle_state.record_action(
            resource_type="EBSSnapshot",
            resource_id=snap_id,
            region=region,
            account_id=_ACCOUNT_ID,
            action_type="detected",
            actor_id=_ACTOR_ID,
            notes=f"AgeDays={age_days}",
        )

    if DRY_RUN:
        return {"finding": finding}

    if cumulative_usd + estimated > COST_CEILING_USD:
        logger.warning("Cost ceiling reached — skipping delete for %s", snap_id)
        idle_state.record_action(
            resource_type="EBSSnapshot",
            resource_id=snap_id,
            region=region,
            account_id=_ACCOUNT_ID,
            action_type="skipped-ceiling",
            actor_id=_ACTOR_ID,
        )
        return {"finding": finding, "ceiling_hit": True}

    ec2.delete_snapshot(SnapshotId=snap_id)
    idle_state.record_action(
        resource_type="EBSSnapshot",
        resource_id=snap_id,
        region=region,
        account_id=_ACCOUNT_ID,
        action_type="deleted",
        actor_id=_ACTOR_ID,
        estimated_savings_usd=estimated,
    )
    return {"finding": finding, "deleted": snap_id}


def _severity(total, aging_count):
    if total > 500 or aging_count > 0:
        return "high"
    if total > 100:
        return "medium"
    return "low"


def _publish_metrics(waste, found, actions, savings):
    dim = [{"Name": "ResourceType", "Value": "EBSSnapshot"}]
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": "MonthlyWasteUsd",
                "Value": float(waste),
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

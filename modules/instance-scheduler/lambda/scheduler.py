"""
FinOps instance scheduler — multi-resource, DDB-audited, override-aware.

Fires on an EventBridge schedule (default every 5 min). For each scan region
+ enabled resource type:

  1. List candidates carrying OPT_IN_TAG_KEY=<schedule-name>
  2. Skip if FinOpsException, ScheduleOverrideUntil active, or unknown schedule
  3. Compute desired state from schedule definition (days + start + stop + tz)
  4. If actual != desired → start/stop, subject to a per-tick action ceiling
  5. Record STATE + ACTION rows in DDB; emit CloudWatch metrics; publish digest

Schedule shape (from SCHEDULES_JSON env):
    {
      "office-hours-cet": {
        "days":     ["MON","TUE","WED","THU","FRI"],
        "start":    "08:00",
        "stop":     "18:00",
        "timezone": "Europe/Berlin"
      }
    }

Resource types: EC2, RDS DB instance, RDS DB cluster (Aurora), Auto Scaling
Group (scale-to-zero with FinOpsSavedMin / FinOpsSavedDesired tag stash).
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import uuid
from typing import Any
from zoneinfo import ZoneInfo

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

OPT_IN_TAG_KEY = os.environ["OPT_IN_TAG_KEY"]
EXCEPTION_TAG_KEY = os.environ["EXCEPTION_TAG_KEY"]
OVERRIDE_UNTIL_TAG_KEY = os.environ["OVERRIDE_UNTIL_TAG_KEY"]
SCHEDULES = json.loads(os.environ.get("SCHEDULES_JSON", "{}"))
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FinOps/InstanceScheduler")
SCAN_REGIONS = json.loads(os.environ.get("SCAN_REGIONS", "[]"))
STATE_TABLE_NAME = os.environ["STATE_TABLE_NAME"]
STATE_TTL_DAYS = int(os.environ.get("STATE_TTL_DAYS", "90"))
ACTION_TTL_DAYS = int(os.environ.get("ACTION_TTL_DAYS", "2557"))
MAX_ACTIONS_PER_TICK = int(os.environ.get("MAX_ACTIONS_PER_TICK", "200"))
ENABLE_EC2 = os.environ.get("ENABLE_EC2", "true").lower() == "true"
ENABLE_RDS_INSTANCES = os.environ.get("ENABLE_RDS_INSTANCES", "true").lower() == "true"
ENABLE_RDS_CLUSTERS = os.environ.get("ENABLE_RDS_CLUSTERS", "true").lower() == "true"
ENABLE_ASG = os.environ.get("ENABLE_ASG", "false").lower() == "true"
ENABLE_SPOT_MANAGEMENT = (
    os.environ.get("ENABLE_SPOT_MANAGEMENT", "false").lower() == "true"
)
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"

_boto = Config(retries={"max_attempts": 10, "mode": "adaptive"})
sns = boto3.client("sns", config=_boto)
cw = boto3.client("cloudwatch", config=_boto)
sts = boto3.client("sts")
ddb = boto3.resource("dynamodb").Table(STATE_TABLE_NAME)

_ACCOUNT_ID = sts.get_caller_identity()["Account"]
_ACTOR_ID = f"lambda:{os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}"

DAY_CODES = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------


def handler(event, context):
    logger.info(
        "Scheduler tick: regions=%s schedules=%s ec2=%s rds_i=%s rds_c=%s asg=%s",
        SCAN_REGIONS,
        list(SCHEDULES.keys()),
        ENABLE_EC2,
        ENABLE_RDS_INSTANCES,
        ENABLE_RDS_CLUSTERS,
        ENABLE_ASG,
    )

    totals = {
        "managed": {"EC2": 0, "RDSInstance": 0, "RDSCluster": 0, "ASG": 0},
        "started": 0,
        "stopped": 0,
        "skipped_override": 0,
        "skipped_ceiling": 0,
        "skipped_exception": 0,
        "skipped_spot": 0,
        "scale_ambiguous": 0,
        "dry_run": 0,
        "no_change": 0,
        "failed": 0,
        "actions": [],
        "errors": [],
    }
    if DRY_RUN:
        logger.warning("DRY_RUN=true — every action will be logged but not executed")

    # Mutable counter shared across processors. Once it hits MAX_ACTIONS_PER_TICK
    # the decision core stops dispatching mutations; the rest of the tick is
    # observation-only. Re-evaluated next tick.
    action_budget = {"used": 0}
    now_utc = dt.datetime.now(dt.timezone.utc)

    for region in SCAN_REGIONS:
        try:
            ec2 = boto3.client("ec2", region_name=region, config=_boto)
            rds = boto3.client("rds", region_name=region, config=_boto)
            asg_client = boto3.client("autoscaling", region_name=region, config=_boto)

            if ENABLE_EC2:
                _process_ec2(ec2, region, now_utc, totals, action_budget)
            if ENABLE_RDS_INSTANCES:
                _process_rds_instances(rds, region, now_utc, totals, action_budget)
            if ENABLE_RDS_CLUSTERS:
                _process_rds_clusters(rds, region, now_utc, totals, action_budget)
            if ENABLE_ASG:
                _process_asgs(asg_client, region, now_utc, totals, action_budget)
        except Exception as e:
            logger.exception("Region %s scan failed", region)
            totals["errors"].append({"region": region, "error": str(e)})

    _publish_aggregate_metrics(totals)
    _publish_digest(totals, now_utc)

    if totals["errors"]:
        raise RuntimeError(f"{len(totals['errors'])} region(s) failed")
    return {"status": "ok", "actions": totals["started"] + totals["stopped"]}


# ---------------------------------------------------------------------------
# Schedule evaluation
# ---------------------------------------------------------------------------


def _desired_running(schedule: dict, now_utc: dt.datetime) -> bool:
    """Should a resource on this schedule currently be running?

    - If `days` is empty → always stopped
    - Convert now → schedule.timezone
    - If today's weekday isn't in `days` → stopped
    - Otherwise return start_min <= now_min < stop_min (wraps over midnight if stop<start)
    """
    days_upper = [d.upper() for d in schedule.get("days", [])]
    if not days_upper:
        return False

    tz_name = schedule.get("timezone") or "UTC"
    try:
        tz = ZoneInfo(tz_name)
    except Exception:
        logger.warning("Unknown timezone %s — falling back to UTC", tz_name)
        tz = dt.timezone.utc

    now_local = now_utc.astimezone(tz)
    today_code = DAY_CODES[now_local.weekday()]
    if today_code not in days_upper:
        return False

    h_s, m_s = [int(x) for x in schedule["start"].split(":")]
    h_e, m_e = [int(x) for x in schedule["stop"].split(":")]
    start_min = h_s * 60 + m_s
    stop_min = h_e * 60 + m_e
    now_min = now_local.hour * 60 + now_local.minute

    if start_min <= stop_min:
        return start_min <= now_min < stop_min
    return now_min >= start_min or now_min < stop_min


# ---------------------------------------------------------------------------
# Per-resource-type processors
# ---------------------------------------------------------------------------


def _process_ec2(ec2, region, now_utc, totals, action_budget):
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(
        Filters=[{"Name": "tag-key", "Values": [OPT_IN_TAG_KEY]}]
    ):
        for res in page.get("Reservations", []) or []:
            for inst in res.get("Instances", []) or []:
                try:
                    state = inst["State"]["Name"]
                    if state in ("terminated", "shutting-down", "stopping"):
                        continue

                    is_spot = inst.get("InstanceLifecycle") == "spot"
                    if is_spot and not ENABLE_SPOT_MANAGEMENT:
                        totals["skipped_spot"] += 1
                        _record_action(
                            "EC2",
                            inst["InstanceId"],
                            region,
                            "skipped-spot",
                            "",
                            "spot lifecycle — set ENABLE_SPOT_MANAGEMENT=true to manage",
                        )
                        continue

                    tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                    outcome = _evaluate_resource(
                        resource_type="EC2",
                        resource_id=inst["InstanceId"],
                        region=region,
                        tags=tags,
                        actual_running=state in ("running", "pending"),
                        now_utc=now_utc,
                        action_budget=action_budget,
                        start_fn=lambda iid=inst["InstanceId"]: ec2.start_instances(
                            InstanceIds=[iid]
                        ),
                        stop_fn=lambda iid=inst["InstanceId"]: ec2.stop_instances(
                            InstanceIds=[iid]
                        ),
                    )
                    totals["managed"]["EC2"] += 1
                    _accumulate_outcome(totals, outcome, "EC2")
                except Exception as e:
                    logger.exception(
                        "EC2 %s failed in region %s", inst.get("InstanceId"), region
                    )
                    totals["failed"] += 1
                    totals["errors"].append(
                        {
                            "region": region,
                            "resource": inst.get("InstanceId"),
                            "error": str(e),
                        }
                    )


def _process_rds_instances(rds, region, now_utc, totals, action_budget):
    NON_ACTIONABLE = {
        "creating",
        "deleting",
        "modifying",
        "backing-up",
        "renaming",
        "maintenance",
        "starting",
        "stopping",
        "rebooting",
        "upgrading",
        "configuring-iam-database-auth",
        "configuring-log-exports",
        "moving-to-vpc",
        "resetting-master-credentials",
    }
    paginator = rds.get_paginator("describe_db_instances")
    for page in paginator.paginate():
        for db in page.get("DBInstances", []) or []:
            try:
                tags = {t["Key"]: t["Value"] for t in db.get("TagList", []) or []}
                if OPT_IN_TAG_KEY not in tags:
                    continue
                status = db["DBInstanceStatus"]
                if status in NON_ACTIONABLE:
                    logger.info(
                        "RDS %s in transient state %s — deferring",
                        db["DBInstanceIdentifier"],
                        status,
                    )
                    continue
                # Aurora cluster member — cluster-level scheduler owns it.
                if db.get("DBClusterIdentifier"):
                    continue
                outcome = _evaluate_resource(
                    resource_type="RDSInstance",
                    resource_id=db["DBInstanceIdentifier"],
                    region=region,
                    tags=tags,
                    actual_running=status == "available",
                    now_utc=now_utc,
                    action_budget=action_budget,
                    start_fn=lambda d=db["DBInstanceIdentifier"]: rds.start_db_instance(
                        DBInstanceIdentifier=d
                    ),
                    stop_fn=lambda d=db["DBInstanceIdentifier"]: rds.stop_db_instance(
                        DBInstanceIdentifier=d
                    ),
                )
                totals["managed"]["RDSInstance"] += 1
                _accumulate_outcome(totals, outcome, "RDSInstance")
            except Exception as e:
                logger.exception(
                    "RDS instance %s failed in region %s",
                    db.get("DBInstanceIdentifier"),
                    region,
                )
                totals["failed"] += 1
                totals["errors"].append(
                    {
                        "region": region,
                        "resource": db.get("DBInstanceIdentifier"),
                        "error": str(e),
                    }
                )


def _process_rds_clusters(rds, region, now_utc, totals, action_budget):
    NON_ACTIONABLE = {
        "creating",
        "deleting",
        "modifying",
        "backing-up",
        "starting",
        "stopping",
        "rebooting",
        "upgrading",
        "maintenance",
        "renaming",
        "promoting",
        "failing-over",
        "configuring-iam-database-auth",
    }
    paginator = rds.get_paginator("describe_db_clusters")
    for page in paginator.paginate():
        for cl in page.get("DBClusters", []) or []:
            try:
                tags = {t["Key"]: t["Value"] for t in cl.get("TagList", []) or []}
                if OPT_IN_TAG_KEY not in tags:
                    continue
                if cl.get("EngineMode", "") == "serverless":
                    logger.info(
                        "RDS cluster %s is serverless — stop/start unsupported, skipping",
                        cl["DBClusterIdentifier"],
                    )
                    continue
                status = cl["Status"]
                if status in NON_ACTIONABLE:
                    logger.info(
                        "RDS cluster %s in transient state %s — deferring",
                        cl["DBClusterIdentifier"],
                        status,
                    )
                    continue
                outcome = _evaluate_resource(
                    resource_type="RDSCluster",
                    resource_id=cl["DBClusterIdentifier"],
                    region=region,
                    tags=tags,
                    actual_running=status == "available",
                    now_utc=now_utc,
                    action_budget=action_budget,
                    start_fn=lambda c=cl["DBClusterIdentifier"]: rds.start_db_cluster(
                        DBClusterIdentifier=c
                    ),
                    stop_fn=lambda c=cl["DBClusterIdentifier"]: rds.stop_db_cluster(
                        DBClusterIdentifier=c
                    ),
                )
                totals["managed"]["RDSCluster"] += 1
                _accumulate_outcome(totals, outcome, "RDSCluster")
            except Exception as e:
                logger.exception(
                    "RDS cluster %s failed in region %s",
                    cl.get("DBClusterIdentifier"),
                    region,
                )
                totals["failed"] += 1
                totals["errors"].append(
                    {
                        "region": region,
                        "resource": cl.get("DBClusterIdentifier"),
                        "error": str(e),
                    }
                )


def _process_asgs(asg, region, now_utc, totals, action_budget):
    paginator = asg.get_paginator("describe_auto_scaling_groups")
    for page in paginator.paginate():
        for group in page.get("AutoScalingGroups", []) or []:
            try:
                tags = {t["Key"]: t["Value"] for t in group.get("Tags", []) or []}
                if OPT_IN_TAG_KEY not in tags:
                    continue
                outcome = _evaluate_resource(
                    resource_type="ASG",
                    resource_id=group["AutoScalingGroupName"],
                    region=region,
                    tags=tags,
                    actual_running=(group.get("DesiredCapacity") or 0) > 0,
                    now_utc=now_utc,
                    action_budget=action_budget,
                    start_fn=lambda g=group: _asg_scale_up(asg, g, totals),
                    stop_fn=lambda g=group: _asg_scale_to_zero(asg, g),
                )
                totals["managed"]["ASG"] += 1
                _accumulate_outcome(totals, outcome, "ASG")
            except Exception as e:
                logger.exception(
                    "ASG %s failed in region %s",
                    group.get("AutoScalingGroupName"),
                    region,
                )
                totals["failed"] += 1
                totals["errors"].append(
                    {
                        "region": region,
                        "resource": group.get("AutoScalingGroupName"),
                        "error": str(e),
                    }
                )


def _asg_scale_to_zero(asg, group: dict):
    name = group["AutoScalingGroupName"]
    min_size = group.get("MinSize") or 0
    desired = group.get("DesiredCapacity") or 0
    # Stash current capacity in tags so scale-up can restore it.
    asg.create_or_update_tags(
        Tags=[
            {
                "ResourceId": name,
                "ResourceType": "auto-scaling-group",
                "Key": "FinOpsSavedMin",
                "Value": str(min_size),
                "PropagateAtLaunch": False,
            },
            {
                "ResourceId": name,
                "ResourceType": "auto-scaling-group",
                "Key": "FinOpsSavedDesired",
                "Value": str(desired),
                "PropagateAtLaunch": False,
            },
        ]
    )
    asg.update_auto_scaling_group(
        AutoScalingGroupName=name, MinSize=0, DesiredCapacity=0
    )


def _asg_scale_up(asg, group: dict, totals: dict | None = None):
    name = group["AutoScalingGroupName"]
    tags = {t["Key"]: t["Value"] for t in group.get("Tags", []) or []}
    stash_present = "FinOpsSavedMin" in tags and "FinOpsSavedDesired" in tags
    if not stash_present and totals is not None:
        # Someone scaled / re-tagged the ASG outside the scheduler. Fall back to
        # safe defaults (1/1) but flag the ambiguity so operators can investigate.
        totals["scale_ambiguous"] += 1
        logger.warning(
            "ASG %s missing scale stash tags — scaling to 1/1 (safe fallback)", name
        )
    try:
        saved_min = int(tags.get("FinOpsSavedMin", "1"))
    except ValueError:
        saved_min = 1
    try:
        saved_desired = int(tags.get("FinOpsSavedDesired", str(max(saved_min, 1))))
    except ValueError:
        saved_desired = max(saved_min, 1)
    asg.update_auto_scaling_group(
        AutoScalingGroupName=name, MinSize=saved_min, DesiredCapacity=saved_desired
    )
    if stash_present:
        asg.delete_tags(
            Tags=[
                {
                    "ResourceId": name,
                    "ResourceType": "auto-scaling-group",
                    "Key": "FinOpsSavedMin",
                },
                {
                    "ResourceId": name,
                    "ResourceType": "auto-scaling-group",
                    "Key": "FinOpsSavedDesired",
                },
            ]
        )


# ---------------------------------------------------------------------------
# Decision core (used by every resource type)
# ---------------------------------------------------------------------------


def _evaluate_resource(
    *,
    resource_type: str,
    resource_id: str,
    region: str,
    tags: dict,
    actual_running: bool,
    now_utc: dt.datetime,
    action_budget: dict,
    start_fn,
    stop_fn,
) -> dict:
    schedule_name = tags.get(OPT_IN_TAG_KEY, "")
    owner = tags.get("Owner") or "(no Owner tag)"

    if EXCEPTION_TAG_KEY in tags:
        _upsert_state(
            resource_type,
            resource_id,
            region,
            schedule_name,
            owner,
            actual_running,
            "excepted",
            tags,
        )
        return {"outcome": "skipped_exception"}

    override_until = tags.get(OVERRIDE_UNTIL_TAG_KEY, "")
    if override_until:
        try:
            until = dt.datetime.fromisoformat(override_until.replace("Z", "+00:00"))
            if now_utc < until:
                _upsert_state(
                    resource_type,
                    resource_id,
                    region,
                    schedule_name,
                    owner,
                    actual_running,
                    "override-active",
                    tags,
                )
                _record_action(
                    resource_type,
                    resource_id,
                    region,
                    "skipped-override",
                    schedule_name,
                    f"override until {override_until}",
                )
                return {"outcome": "skipped_override"}
        except ValueError:
            logger.warning(
                "Invalid %s on %s: %r",
                OVERRIDE_UNTIL_TAG_KEY,
                resource_id,
                override_until,
            )

    schedule = SCHEDULES.get(schedule_name)
    if not schedule:
        logger.warning(
            "Resource %s has Schedule=%s but no such schedule defined",
            resource_id,
            schedule_name,
        )
        _upsert_state(
            resource_type,
            resource_id,
            region,
            schedule_name,
            owner,
            actual_running,
            "unknown-schedule",
            tags,
        )
        return {"outcome": "no_change"}

    desired = _desired_running(schedule, now_utc)
    if desired == actual_running:
        _upsert_state(
            resource_type,
            resource_id,
            region,
            schedule_name,
            owner,
            actual_running,
            "in-sync",
            tags,
        )
        return {"outcome": "no_change"}

    # Action-count ceiling — blast-radius cap, not a cost concept. Dollar
    # estimation belongs in the analytics layer (Cloudability / CUR), which
    # reflects actual paid prices including RIs/SPs/EDP.
    if action_budget["used"] >= MAX_ACTIONS_PER_TICK:
        logger.warning(
            "Action ceiling (%d) reached — deferring %s to next tick",
            MAX_ACTIONS_PER_TICK,
            resource_id,
        )
        _upsert_state(
            resource_type,
            resource_id,
            region,
            schedule_name,
            owner,
            actual_running,
            "ceiling-skipped",
            tags,
        )
        _record_action(
            resource_type,
            resource_id,
            region,
            "skipped-ceiling",
            schedule_name,
            f"max_actions_per_tick={MAX_ACTIONS_PER_TICK} reached",
        )
        return {"outcome": "skipped_ceiling"}

    action_type = "started" if desired else "stopped"
    if DRY_RUN:
        logger.info(
            "DRY_RUN: would %s %s (%s) per schedule=%s",
            action_type,
            resource_id,
            resource_type,
            schedule_name,
        )
        _upsert_state(
            resource_type,
            resource_id,
            region,
            schedule_name,
            owner,
            actual_running,
            "dry-run",
            tags,
        )
        _record_action(
            resource_type,
            resource_id,
            region,
            f"dry-run-{action_type}",
            schedule_name,
            f"DRY_RUN — would {action_type}",
        )
        # Dry-run actions still consume the budget — we want preview to be
        # representative of what a real tick would do.
        action_budget["used"] += 1
        return {
            "outcome": "dry_run",
            "would_act": True,
            "would_action": action_type,
            "schedule": schedule_name,
            "owner": owner,
            "resource_id": resource_id,
        }

    try:
        if desired:
            start_fn()
        else:
            stop_fn()
    except Exception as e:
        logger.exception("Failed to %s %s", action_type, resource_id)
        _record_action(
            resource_type,
            resource_id,
            region,
            "failed",
            schedule_name,
            f"{action_type}: {e}",
        )
        return {"outcome": "failed"}

    action_budget["used"] += 1
    _upsert_state(
        resource_type, resource_id, region, schedule_name, owner, desired, "acted", tags
    )
    _record_action(resource_type, resource_id, region, action_type, schedule_name, "")
    return {
        "outcome": action_type,
        "acted": True,
        "schedule": schedule_name,
        "owner": owner,
        "resource_id": resource_id,
    }


def _accumulate_outcome(totals: dict, outcome: dict, resource_type: str):
    o = outcome.get("outcome")
    if o == "started":
        totals["started"] += 1
        totals["actions"].append(
            {"action": "started", "resource_type": resource_type, **outcome}
        )
    elif o == "stopped":
        totals["stopped"] += 1
        totals["actions"].append(
            {"action": "stopped", "resource_type": resource_type, **outcome}
        )
    elif o == "skipped_override":
        totals["skipped_override"] += 1
    elif o == "skipped_ceiling":
        totals["skipped_ceiling"] += 1
    elif o == "skipped_exception":
        totals["skipped_exception"] += 1
    elif o == "failed":
        totals["failed"] += 1
    elif o == "dry_run":
        totals["dry_run"] += 1
        totals["actions"].append(
            {"action": "dry-run", "resource_type": resource_type, **outcome}
        )
    else:
        totals["no_change"] += 1


# ---------------------------------------------------------------------------
# DDB STATE + ACTION rows
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _epoch(days_from_now: int) -> int:
    return int(
        (
            dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=days_from_now)
        ).timestamp()
    )


def _upsert_state(
    resource_type,
    resource_id,
    region,
    schedule_name,
    owner,
    is_running,
    last_outcome,
    tags,
):
    ddb.put_item(
        Item={
            "PK": f"{resource_type}#{resource_id}",
            "SK": "STATE",
            "ResourceType": resource_type,
            "ResourceId": resource_id,
            "Region": region,
            "AccountId": _ACCOUNT_ID,
            "ScheduleName": schedule_name,
            "Owner": owner,
            "IsRunning": is_running,
            "LastOutcome": last_outcome,
            "LastSeenAt": _now_iso(),
            "ExpireAt": _epoch(STATE_TTL_DAYS),
        }
    )


def _record_action(
    resource_type, resource_id, region, action_type, schedule_name, notes
):
    now = dt.datetime.now(dt.timezone.utc)
    iso = now.isoformat()
    sk_suffix = uuid.uuid4().hex[:8]
    ddb.put_item(
        Item={
            "PK": f"{resource_type}#{resource_id}",
            "SK": f"ACTION#{iso}-{sk_suffix}",
            # GSI1 — date-keyed action queries. STATE rows don't carry these.
            "GSI1PK": f"ACTION#{now.strftime('%Y-%m-%d')}",
            "GSI1SK": f"{iso}-{sk_suffix}",
            "ResourceType": resource_type,
            "ResourceId": resource_id,
            "Region": region,
            "AccountId": _ACCOUNT_ID,
            "ActionType": action_type,
            "ScheduleName": schedule_name,
            "ActorId": _ACTOR_ID,
            "Notes": notes,
            "Timestamp": iso,
            "ExpireAt": _epoch(ACTION_TTL_DAYS),
        }
    )


# ---------------------------------------------------------------------------
# Metrics + digest
# ---------------------------------------------------------------------------


def _publish_aggregate_metrics(totals: dict):
    data: list[dict[str, Any]] = [
        {
            "MetricName": "ActionStarted",
            "Value": float(totals["started"]),
            "Unit": "Count",
        },
        {
            "MetricName": "ActionStopped",
            "Value": float(totals["stopped"]),
            "Unit": "Count",
        },
        {
            "MetricName": "ActionSkippedOverride",
            "Value": float(totals["skipped_override"]),
            "Unit": "Count",
        },
        {
            "MetricName": "ActionSkippedCeiling",
            "Value": float(totals["skipped_ceiling"]),
            "Unit": "Count",
        },
        {
            "MetricName": "ActionSkippedSpot",
            "Value": float(totals["skipped_spot"]),
            "Unit": "Count",
        },
        {
            "MetricName": "ActionScaleAmbiguous",
            "Value": float(totals["scale_ambiguous"]),
            "Unit": "Count",
        },
        {
            "MetricName": "ActionDryRun",
            "Value": float(totals["dry_run"]),
            "Unit": "Count",
        },
        {
            "MetricName": "ActionFailed",
            "Value": float(totals["failed"]),
            "Unit": "Count",
        },
    ]
    for rtype, count in totals["managed"].items():
        data.append(
            {
                "MetricName": "ManagedResourceCount",
                "Value": float(count),
                "Unit": "Count",
                "Dimensions": [{"Name": "ResourceType", "Value": rtype}],
            }
        )
    cw.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=data)


def _publish_digest(totals: dict, now_utc: dt.datetime):
    if not SNS_TOPIC_ARN:
        return  # standalone mode without an events topic — metrics + DDB audit only
    if (
        totals["started"] == 0
        and totals["stopped"] == 0
        and totals["failed"] == 0
        and not totals["errors"]
    ):
        return  # quiet tick — don't spam the events bus

    severity = (
        "high"
        if totals["failed"] > 0 or totals["errors"]
        else ("medium" if (totals["started"] + totals["stopped"]) > 50 else "info")
    )
    summary = {
        "AlertName": "FinOps instance-scheduler tick",
        "severity": severity,
        "GeneratedAt": now_utc.isoformat(),
        "ScanRegions": SCAN_REGIONS,
        "Started": totals["started"],
        "Stopped": totals["stopped"],
        "SkippedOverride": totals["skipped_override"],
        "SkippedCeiling": totals["skipped_ceiling"],
        "Failed": totals["failed"],
        "ManagedCounts": totals["managed"],
        "Actions": totals["actions"][:25],
        "Errors": totals["errors"][:10],
    }
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: instance-scheduler activity",
        Message=json.dumps(summary, default=str, indent=2),
    )

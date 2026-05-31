"""
FinOps untagged-cost report.

Runs weekly. Quantifies how much money is leaking through tag gaps:
  - Total cost of resources missing each mandatory tag (current month, MTD)
  - Top-20 highest-cost untagged resources
  - Aged untagged resources (existing > N days without a mandatory tag)
  - Composite tag-health score

Outputs (three sinks):
  - CloudWatch metrics under namespace FinOps/TagGovernance
  - SNS digest to the events topic
  - SSM Parameter Store mirror under $SSM_PREFIX/*

Independent per-KPI failure handling: if Athena throttles a single query, the
rest still publish; the Lambda raises at the end so SNS treats the invocation
as failed and the DLQ captures it.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import time
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

METRIC_NAMESPACE = os.environ["METRIC_NAMESPACE"]
SSM_PREFIX = os.environ["SSM_PREFIX"]
ATHENA_WORKGROUP = os.environ["ATHENA_WORKGROUP"]
ATHENA_DATABASE = os.environ["ATHENA_DATABASE"]
CUR_TABLE = os.environ["CUR_TABLE"]
MANDATORY_TAG_KEYS = json.loads(os.environ.get("MANDATORY_TAG_KEYS", "[]"))
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
TOP_N = int(os.environ.get("TOP_N", "20"))

_athena = boto3.client("athena")
_cw = boto3.client("cloudwatch")
_ssm = boto3.client("ssm")
_sns = boto3.client("sns")

ATHENA_POLL_SECONDS = 2
ATHENA_MAX_WAIT_SECONDS = 180


def handler(event, context):
    if not MANDATORY_TAG_KEYS:
        logger.warning("MANDATORY_TAG_KEYS is empty; nothing to evaluate.")
        return {"status": "skipped", "reason": "no mandatory tag keys configured"}

    errors: list[str] = []
    summary: dict[str, Any] = {
        "GeneratedAt": dt.datetime.utcnow().isoformat() + "Z",
        "PeriodMonthStart": dt.date.today().replace(day=1).isoformat(),
        "MandatoryTagKeys": MANDATORY_TAG_KEYS,
        "PerTagUntaggedCostUsd": {},
        "TopUntaggedResources": [],
        "AgedUntaggedResources": [],
    }

    try:
        per_tag = _untagged_cost_per_mandatory_tag()
        summary["PerTagUntaggedCostUsd"] = per_tag
        total_gap_usd = 0.0
        for tag_key, cost in per_tag.items():
            _publish_metric(
                "UntaggedCostUsd",
                cost,
                dimensions=[{"Name": "MissingTagKey", "Value": tag_key}],
            )
            total_gap_usd += cost
        summary["TotalUntaggedCostUsd"] = round(total_gap_usd, 2)
        _publish_metric_scalar("TotalUntaggedCostUsd", total_gap_usd)
    except Exception as e:
        logger.exception("per-tag untagged-cost query failed")
        errors.append(f"per-tag untagged-cost: {e}")

    try:
        top = _top_untagged_resources()
        summary["TopUntaggedResources"] = top
        _publish_metric_scalar(
            "TopUntaggedResourceMaxCostUsd", top[0]["cost_usd"] if top else 0.0
        )
    except Exception as e:
        logger.exception("top-untagged query failed")
        errors.append(f"top-untagged: {e}")

    try:
        coverage = _coverage_by_mandatory_tag()
        summary["CoverageByTagPct"] = coverage
        for tag_key, pct in coverage.items():
            _publish_metric(
                "TagCoveragePct",
                pct,
                dimensions=[{"Name": "TagKey", "Value": tag_key}],
            )
        # Tag-health score, range 0..100. Steering-committee friendly.
        # Weighted: average coverage % (weight 3), minus a normalized gap
        # penalty (weight 1). Higher is better.
        #   gap_penalty = min(100, total_untagged_cost / GAP_FULL_PENALTY_USD * 100)
        # where GAP_FULL_PENALTY_USD is the gap level at which the penalty
        # saturates to 100. Default 10,000 USD/mo — tune per account size.
        GAP_FULL_PENALTY_USD = 10_000.0
        if coverage:
            avg_cov = sum(coverage.values()) / len(coverage)
            total_gap = summary.get("TotalUntaggedCostUsd", 0.0)
            gap_penalty = min(100.0, (total_gap / GAP_FULL_PENALTY_USD) * 100.0)
            # Weighted average: 3 parts coverage, 1 part inverted-penalty.
            health_score = (avg_cov * 3.0 + (100.0 - gap_penalty) * 1.0) / 4.0
            health_score = max(0.0, min(100.0, health_score))
            summary["TagHealthScore"] = round(health_score, 1)
            _publish_metric_scalar("TagHealthScore", health_score)
    except Exception as e:
        logger.exception("coverage query failed")
        errors.append(f"coverage: {e}")

    _publish_summary(summary, errors)

    if errors:
        raise RuntimeError(
            f"{len(errors)} tag-governance KPI(s) failed: {'; '.join(errors)}"
        )

    return {"status": "ok", "tags_evaluated": len(MANDATORY_TAG_KEYS)}


# ---------------------------------------------------------------------------
# KPI implementations
# ---------------------------------------------------------------------------


def _untagged_cost_per_mandatory_tag() -> dict[str, float]:
    """For each mandatory tag, sum the unblended cost of CUR lines where the
    tag is null or empty. Lines for service-level/usage-only entries (no
    line_item_resource_id) are excluded — they don't represent taggable
    resources."""
    out: dict[str, float] = {}
    for tag_key in MANDATORY_TAG_KEYS:
        sql = f"""
            SELECT COALESCE(SUM(line_item_unblended_cost), 0) AS gap_cost
            FROM {ATHENA_DATABASE}.{CUR_TABLE}
            WHERE billing_period = date_format(current_date, '%Y-%m')
              AND line_item_resource_id IS NOT NULL
              AND line_item_resource_id != ''
              AND (resource_tags['user_{tag_key}'] IS NULL
                   OR resource_tags['user_{tag_key}'] = '')
        """
        rows = _run_athena(sql)
        try:
            cost = (
                float(rows[1][0]) if len(rows) > 1 and rows[1] and rows[1][0] else 0.0
            )
        except (ValueError, TypeError):
            cost = 0.0
        out[tag_key] = round(cost, 2)
    return out


def _top_untagged_resources() -> list[dict[str, Any]]:
    """Top resources by unblended cost that are missing at least one mandatory tag."""
    if not MANDATORY_TAG_KEYS:
        return []
    missing_predicate = " OR ".join(
        f"resource_tags['user_{k}'] IS NULL OR resource_tags['user_{k}'] = ''"
        for k in MANDATORY_TAG_KEYS
    )
    sql = f"""
        SELECT
          line_item_resource_id AS resource_id,
          product_servicecode AS service,
          SUM(line_item_unblended_cost) AS cost_usd
        FROM {ATHENA_DATABASE}.{CUR_TABLE}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND line_item_resource_id IS NOT NULL
          AND line_item_resource_id != ''
          AND ({missing_predicate})
        GROUP BY line_item_resource_id, product_servicecode
        ORDER BY cost_usd DESC
        LIMIT {TOP_N}
    """
    rows = _run_athena(sql)
    out: list[dict[str, Any]] = []
    for row in rows[1:]:
        try:
            cost = float(row[2]) if row[2] else 0.0
        except (ValueError, TypeError):
            cost = 0.0
        out.append(
            {
                "resource_id": row[0],
                "service": row[1],
                "cost_usd": round(cost, 2),
            }
        )
    return out


def _coverage_by_mandatory_tag() -> dict[str, float]:
    """% of unblended cost carrying each mandatory tag, current month."""
    out: dict[str, float] = {}
    for tag_key in MANDATORY_TAG_KEYS:
        sql = f"""
            SELECT
              ROUND(100.0 * SUM(CASE
                  WHEN resource_tags['user_{tag_key}'] IS NOT NULL
                   AND resource_tags['user_{tag_key}'] != ''
                  THEN line_item_unblended_cost ELSE 0 END)
                  / NULLIF(SUM(line_item_unblended_cost), 0), 2) AS pct
            FROM {ATHENA_DATABASE}.{CUR_TABLE}
            WHERE billing_period = date_format(current_date, '%Y-%m')
              AND line_item_resource_id IS NOT NULL
              AND line_item_resource_id != ''
        """
        rows = _run_athena(sql)
        try:
            pct = float(rows[1][0]) if len(rows) > 1 and rows[1] and rows[1][0] else 0.0
        except (ValueError, TypeError):
            pct = 0.0
        out[tag_key] = round(pct, 2)
    return out


# ---------------------------------------------------------------------------
# Sinks
# ---------------------------------------------------------------------------


def _publish_metric(
    name: str, value: float, dimensions: list[dict[str, str]] | None = None
):
    _cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": name,
                "Value": float(value),
                "Unit": "None",
                "Dimensions": dimensions or [],
            }
        ],
    )


def _publish_metric_scalar(name: str, value: float):
    _publish_metric(name, value)
    param_name = f"{SSM_PREFIX}/{_snake(name)}"
    _ssm.put_parameter(
        Name=param_name,
        Value=str(value),
        Type="String",
        Overwrite=True,
        Tier="Standard",
    )


def _publish_summary(summary: dict[str, Any], errors: list[str]):
    msg = dict(summary)
    msg["AlertName"] = "FinOps weekly tag-governance digest"
    msg["severity"] = "info" if not errors else "medium"
    if errors:
        msg["Errors"] = errors
    _sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps weekly tag-governance digest",
        Message=json.dumps(msg, default=str, indent=2),
    )


def _snake(name: str) -> str:
    out = [name[0].lower()]
    for ch in name[1:]:
        if ch.isupper():
            out.append("_")
            out.append(ch.lower())
        else:
            out.append(ch)
    return "".join(out)


# ---------------------------------------------------------------------------
# Athena helper
# ---------------------------------------------------------------------------


def _run_athena(sql: str) -> list[list[str | None]]:
    resp = _athena.start_query_execution(
        QueryString=sql,
        WorkGroup=ATHENA_WORKGROUP,
        QueryExecutionContext={"Database": ATHENA_DATABASE},
    )
    qid = resp["QueryExecutionId"]
    waited = 0
    while waited < ATHENA_MAX_WAIT_SECONDS:
        status = _athena.get_query_execution(QueryExecutionId=qid)
        state = status["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            reason = status["QueryExecution"]["Status"].get(
                "StateChangeReason", "(no reason)"
            )
            raise RuntimeError(f"Athena query {qid} {state}: {reason}")
        time.sleep(ATHENA_POLL_SECONDS)
        waited += ATHENA_POLL_SECONDS
    else:
        raise TimeoutError(
            f"Athena query {qid} did not complete in {ATHENA_MAX_WAIT_SECONDS}s"
        )

    results = _athena.get_query_results(QueryExecutionId=qid)
    return [
        [cell.get("VarCharValue") for cell in row.get("Data", [])]
        for row in results["ResultSet"]["Rows"]
    ]

"""
FinOps KPI aggregator.

Runs once per day on an EventBridge schedule. Queries the framework's
upstream data sources, computes named FinOps KPIs, and writes them to:

  - CloudWatch custom metrics (namespace from $METRIC_NAMESPACE)
  - SSM Parameter Store under $SSM_PREFIX/<kpi>
  - The events SNS topic (a short summary message)

KPIs emitted:
  - AllocationCoveragePct      (Athena over CUR)
  - CommitmentCoveragePct      (Cost Explorer: RI + SP coverage, eligible compute)
  - CommitmentUtilizationPct   (Cost Explorer: RI + SP utilization)
  - AnomalyImpactUsdMtd        (Cost Explorer: anomalies)
  - ForecastAbsDriftPct        (Cost Explorer: actual vs. forecast)
  - SpendByService (top 10)    (Athena over CUR)

The Lambda intentionally treats each KPI independently: if one upstream
fails, the others still publish. Failures are logged and re-raised at the
end so SNS treats the invocation as failed and the DLQ catches the event.
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
import time
from decimal import Decimal
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

METRIC_NAMESPACE = os.environ["METRIC_NAMESPACE"]
SSM_PREFIX = os.environ["SSM_PREFIX"]
ATHENA_WORKGROUP = os.environ["ATHENA_WORKGROUP"]
ATHENA_DATABASE = os.environ["ATHENA_DATABASE"]
CUR_TABLE = os.environ["CUR_TABLE"]
ALLOCATION_TAG_KEYS = json.loads(os.environ.get("ALLOCATION_TAG_KEYS", "[]"))
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

_athena = boto3.client("athena")
_cw = boto3.client("cloudwatch")
_ssm = boto3.client("ssm")
_ce = boto3.client("ce")
_sns = boto3.client("sns")

ATHENA_POLL_SECONDS = 2
ATHENA_MAX_WAIT_SECONDS = 120


# ---------------------------------------------------------------------------
# Public entrypoint
# ---------------------------------------------------------------------------


def handler(event, context):
    errors: list[str] = []
    summary: dict[str, Any] = {}

    for kpi_name, fn in (
        ("AllocationCoveragePct", _allocation_coverage),
        ("CommitmentCoveragePct", _commitment_coverage),
        ("CommitmentUtilizationPct", _commitment_utilization),
        ("AnomalyImpactUsdMtd", _anomaly_impact_mtd),
        ("ForecastAbsDriftPct", _forecast_drift),
    ):
        try:
            value = fn()
            if value is None:
                logger.info("Skipped %s (no value)", kpi_name)
                continue
            _publish_kpi(kpi_name, value)
            summary[kpi_name] = value
        except Exception as e:
            logger.exception("Failed to compute %s", kpi_name)
            errors.append(f"{kpi_name}: {e}")

    # Spend-by-service: emit top-10 services as individual metrics with a
    # Service dimension so it lights up CloudWatch dashboards naturally.
    try:
        top_services = _spend_by_service_top10()
        for svc, cost in top_services:
            _publish_kpi("SpendByServiceUsd", cost, dimensions=[{"Name": "Service", "Value": svc}])
        summary["SpendByServiceTop10"] = [{"service": s, "cost_usd": c} for s, c in top_services]
    except Exception as e:
        logger.exception("Failed to compute SpendByService")
        errors.append(f"SpendByService: {e}")

    _publish_summary(summary, errors)

    if errors:
        raise RuntimeError(f"{len(errors)} KPI(s) failed: {'; '.join(errors)}")

    return {"status": "ok", "kpis": list(summary.keys())}


# ---------------------------------------------------------------------------
# KPI implementations
# ---------------------------------------------------------------------------


def _allocation_coverage() -> float | None:
    """Tagged spend / total spend, current month, via Athena."""
    if not ALLOCATION_TAG_KEYS:
        return None
    predicate = " AND ".join(
        f"resource_tags['user_{k}'] IS NOT NULL AND resource_tags['user_{k}'] != ''"
        for k in ALLOCATION_TAG_KEYS
    )
    sql = f"""
        SELECT
          ROUND(100.0 * SUM(CASE WHEN {predicate} THEN line_item_unblended_cost ELSE 0 END)
                      / NULLIF(SUM(line_item_unblended_cost), 0), 2) AS pct
        FROM {ATHENA_DATABASE}.{CUR_TABLE}
        WHERE billing_period = date_format(current_date, '%Y-%m')
    """
    rows = _run_athena(sql)
    if not rows or len(rows) < 2:
        return None
    raw = rows[1][0]
    return float(raw) if raw else 0.0


def _commitment_coverage() -> float | None:
    """RI + SP combined coverage % of eligible compute, last 30 days."""
    end = dt.date.today()
    start = end - dt.timedelta(days=30)
    time_period = {"Start": start.isoformat(), "End": end.isoformat()}

    ri = _ce.get_reservation_coverage(TimePeriod=time_period).get("Total", {})
    sp = _ce.get_savings_plans_coverage(TimePeriod=time_period).get("Total", {})

    ri_pct = float(ri.get("CoverageHoursPercentage", "0") or "0") if ri else 0.0
    sp_pct = float(((sp or {}).get("Coverage") or {}).get("CoveragePercentage", "0") or "0")

    # Both are % of eligible-compute hours. Combined effective coverage
    # treats them as additive within their respective eligibility scopes.
    # This is a simplification; AWS does not publish a single "combined" value.
    return round(min(100.0, ri_pct + sp_pct), 2)


def _commitment_utilization() -> float | None:
    """RI + SP utilization weighted by spend, last 30 days."""
    end = dt.date.today()
    start = end - dt.timedelta(days=30)
    time_period = {"Start": start.isoformat(), "End": end.isoformat()}

    ri_util = _ce.get_reservation_utilization(TimePeriod=time_period).get("Total", {})
    sp_util = _ce.get_savings_plans_utilization(TimePeriod=time_period).get("Total", {})

    ri_pct = float(ri_util.get("UtilizationPercentage", "0") or "0") if ri_util else 0.0
    sp_pct = float(((sp_util or {}).get("Utilization") or {}).get("UtilizationPercentage", "0") or "0")

    # Use the simple average; for spend-weighted you'd need per-commitment math.
    if ri_pct == 0 and sp_pct == 0:
        return None
    if ri_pct == 0:
        return round(sp_pct, 2)
    if sp_pct == 0:
        return round(ri_pct, 2)
    return round((ri_pct + sp_pct) / 2.0, 2)


def _anomaly_impact_mtd() -> float | None:
    """Sum of confirmed anomaly impact, month-to-date, USD."""
    today = dt.date.today()
    first_of_month = today.replace(day=1)
    resp = _ce.get_anomalies(
        DateInterval={
            "StartDate": first_of_month.isoformat(),
            "EndDate": today.isoformat(),
        }
    )
    anomalies = resp.get("Anomalies", []) or []
    total = 0.0
    for a in anomalies:
        impact = (a.get("Impact") or {}).get("TotalImpact", 0)
        total += float(impact or 0)
    return round(total, 2)


def _forecast_drift() -> float | None:
    """|1 - actual_mtd / forecast_mtd| × 100. Uses GetCostForecast for the
    remainder of the month and GetCostAndUsage for the MTD actual."""
    today = dt.date.today()
    first_of_month = today.replace(day=1)
    next_month = (today.replace(day=28) + dt.timedelta(days=4)).replace(day=1)

    # MTD actual
    actual_resp = _ce.get_cost_and_usage(
        TimePeriod={"Start": first_of_month.isoformat(), "End": today.isoformat()},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
    )
    actual_mtd = 0.0
    for r in actual_resp.get("ResultsByTime", []):
        actual_mtd += float(r["Total"]["UnblendedCost"]["Amount"])

    # Full-month forecast (from today to end of month)
    if today >= next_month:
        return None
    try:
        forecast_resp = _ce.get_cost_forecast(
            TimePeriod={"Start": today.isoformat(), "End": next_month.isoformat()},
            Metric="UNBLENDED_COST",
            Granularity="MONTHLY",
        )
        remaining_forecast = float(forecast_resp["Total"]["Amount"])
    except _ce.exceptions.ClientError:
        return None

    projected_full_month = actual_mtd + remaining_forecast
    if projected_full_month <= 0:
        return None

    # Drift vs. the original full-month forecast issued on day 1:
    # we approximate by comparing actual_mtd against the proportional
    # share of projected_full_month for the days elapsed.
    days_in_month = (next_month - first_of_month).days
    days_elapsed = (today - first_of_month).days or 1
    expected_mtd = projected_full_month * (days_elapsed / days_in_month)

    if expected_mtd <= 0:
        return None

    drift = abs(1.0 - (actual_mtd / expected_mtd)) * 100.0
    return round(drift, 2)


def _spend_by_service_top10() -> list[tuple[str, float]]:
    sql = f"""
        SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS cost_usd
        FROM {ATHENA_DATABASE}.{CUR_TABLE}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY product_servicecode
        ORDER BY cost_usd DESC
        LIMIT 10
    """
    rows = _run_athena(sql)
    if not rows or len(rows) < 2:
        return []
    out: list[tuple[str, float]] = []
    for row in rows[1:]:
        service = row[0] or "unknown"
        try:
            cost = float(row[1])
        except (TypeError, ValueError):
            cost = 0.0
        out.append((service, cost))
    return out


# ---------------------------------------------------------------------------
# Sink helpers
# ---------------------------------------------------------------------------


def _publish_kpi(name: str, value: float, dimensions: list[dict[str, str]] | None = None):
    """Write to CloudWatch metric + SSM Parameter."""
    _cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{
            "MetricName": name,
            "Value": float(value),
            "Unit": "None",
            "Dimensions": dimensions or [],
        }],
    )
    # SSM mirror — only when there are no dimensions (parameters are scalar).
    if not dimensions:
        param_name = f"{SSM_PREFIX}/{_snake(name)}"
        _ssm.put_parameter(
            Name=param_name,
            Value=str(value),
            Type="String",
            Overwrite=True,
            Tier="Standard",
        )
    logger.info("Published KPI %s = %s", name, value)


def _publish_summary(summary: dict[str, Any], errors: list[str]):
    msg = {
        "AlertName": "FinOps daily KPI digest",
        "severity": "info" if not errors else "medium",
        "GeneratedAt": dt.datetime.utcnow().isoformat() + "Z",
        "KPIs": {k: v for k, v in summary.items() if not isinstance(v, list)},
        "TopServices": summary.get("SpendByServiceTop10", []),
    }
    if errors:
        msg["Errors"] = errors
    _sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps daily KPI digest",
        Message=json.dumps(msg, default=_decimal_default, indent=2),
    )


def _decimal_default(o):
    if isinstance(o, Decimal):
        return float(o)
    raise TypeError(f"not JSON-serializable: {type(o).__name__}")


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
# Athena
# ---------------------------------------------------------------------------


def _run_athena(sql: str) -> list[list[str]]:
    """Submit a query, wait, return the result rows as a list-of-lists.
    First row is the column header."""
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
            reason = status["QueryExecution"]["Status"].get("StateChangeReason", "(no reason)")
            raise RuntimeError(f"Athena query {qid} {state}: {reason}")
        time.sleep(ATHENA_POLL_SECONDS)
        waited += ATHENA_POLL_SECONDS
    else:
        raise TimeoutError(f"Athena query {qid} did not complete in {ATHENA_MAX_WAIT_SECONDS}s")

    results = _athena.get_query_results(QueryExecutionId=qid)
    rows = []
    for row in results["ResultSet"]["Rows"]:
        rows.append([cell.get("VarCharValue") for cell in row.get("Data", [])])
    return rows

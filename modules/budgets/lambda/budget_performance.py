"""
FinOps budget performance monitor.

Runs daily. For each AWS Budget in the account:
  - Reads actual vs forecasted spend (from the Budget itself)
  - Calculates VariancePct = (actual − limit) / limit × 100
  - Calculates BurnRateDaysToBreach = (limit − actual) / (actual / days_elapsed)
  - Correlates with active Cost Anomaly Detection findings
  - Writes a STATE row (current) + SNAPSHOT#<date> row (trend, 1y TTL)
  - Emits CloudWatch metrics under FinOps/Budgets:
      VariancePct (per-Budget dim), BurnRateDaysToBreach (per-Budget dim),
      BudgetAdherenceScore (aggregate), ActiveBudgetCount (aggregate)
  - Mirrors aggregate scalars to SSM Parameter Store
  - Publishes a structured digest to the events SNS topic with top breaches +
    top burn-rate budgets so the chat-notifier can render it richly
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
from decimal import Decimal
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

STATE_TABLE_NAME = os.environ["STATE_TABLE_NAME"]
METRIC_NAMESPACE = os.environ["METRIC_NAMESPACE"]
SSM_PREFIX = os.environ["SSM_PREFIX"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

budgets = boto3.client("budgets")
ce = boto3.client("ce")
cw = boto3.client("cloudwatch")
sns = boto3.client("sns")
ssm = boto3.client("ssm")
sts = boto3.client("sts")
ddb = boto3.resource("dynamodb")

_ACCOUNT_ID = sts.get_caller_identity()["Account"]
_ACTOR_ID = f"lambda:{os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}"
_TABLE = ddb.Table(STATE_TABLE_NAME)

SNAPSHOT_TTL_DAYS = 400  # ~13 months of daily snapshots
STATE_TTL_DAYS = 90       # ~3 months after a budget stops appearing


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _to_decimal(v: Any) -> Any:
    if isinstance(v, float):
        return Decimal(str(round(v, 4)))
    if isinstance(v, dict):
        return {k: _to_decimal(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_to_decimal(x) for x in v]
    return v


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _epoch(days_from_now: int) -> int:
    return int((_now() + dt.timedelta(days=days_from_now)).timestamp())


def _period_bounds(time_unit: str, today: dt.date) -> tuple[dt.date, dt.date]:
    """Return (period_start, next_period_start) for a given Budget time unit."""
    if time_unit == "MONTHLY":
        start = today.replace(day=1)
        next_start = (today.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
    elif time_unit == "QUARTERLY":
        q = (today.month - 1) // 3
        start = today.replace(month=q * 3 + 1, day=1)
        if q == 3:
            next_start = start.replace(year=start.year + 1, month=1, day=1)
        else:
            next_start = start.replace(month=start.month + 3)
    else:  # ANNUALLY
        start = today.replace(month=1, day=1)
        next_start = start.replace(year=start.year + 1)
    return start, next_start


def _publish_metric(name: str, value: float, dimensions: list[dict[str, str]] | None = None):
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{
            "MetricName": name,
            "Value": float(value),
            "Unit": "None",
            "Dimensions": dimensions or [],
        }],
    )


def _put_ssm(name: str, value: float):
    ssm.put_parameter(
        Name=f"{SSM_PREFIX}/{name}",
        Value=str(value),
        Type="String",
        Overwrite=True,
        Tier="Standard",
    )


# ---------------------------------------------------------------------------
# Main handler
# ---------------------------------------------------------------------------


def handler(event, context):
    today = dt.date.today()
    now_iso = _now().isoformat()
    date_iso = today.isoformat()

    # 1) Load active anomalies for correlation
    first_of_month = today.replace(day=1)
    try:
        anomalies_resp = ce.get_anomalies(
            DateInterval={"StartDate": first_of_month.isoformat(), "EndDate": today.isoformat()},
        )
        anomalies = anomalies_resp.get("Anomalies", []) or []
    except Exception:
        logger.exception("Failed to fetch anomalies; proceeding without correlation")
        anomalies = []
    anomaly_active = bool(anomalies)
    anomaly_count = len(anomalies)

    # 2) List all budgets (paginated)
    all_budgets: list[dict] = []
    paginator = budgets.get_paginator("describe_budgets")
    for page in paginator.paginate(AccountId=_ACCOUNT_ID):
        all_budgets.extend(page.get("Budgets", []) or [])

    if not all_budgets:
        logger.info("No budgets found in account.")
        _publish_metric("ActiveBudgetCount", 0.0)
        _publish_metric("BudgetAdherenceScore", 100.0)
        return {"status": "ok", "active_budgets": 0}

    # 3) Process each budget
    per_budget: list[dict] = []
    errors: list[dict] = []
    for budget in all_budgets:
        try:
            per_budget.append(_process_budget(budget, today, date_iso, now_iso, anomaly_active, anomaly_count))
        except Exception as e:
            logger.exception("Failed processing budget %s", budget.get("BudgetName"))
            errors.append({"budget": budget.get("BudgetName"), "error": str(e)})

    # 4) Aggregate KPIs
    active_count = len(per_budget)
    adherent_count = sum(1 for r in per_budget if r["IsAdherent"])
    adherence_score = round(100.0 * adherent_count / max(active_count, 1), 1)

    _publish_metric("ActiveBudgetCount", float(active_count))
    _publish_metric("BudgetAdherenceScore", adherence_score)
    _put_ssm("budget_adherence_score", adherence_score)
    _put_ssm("active_budget_count", active_count)

    # Approaching-breach count: budgets with days-to-breach < 14
    approaching = [r for r in per_budget if r["DaysToBreach"] is not None and 0 <= r["DaysToBreach"] < 14]
    _publish_metric("ApproachingBreachCount", float(len(approaching)))

    # 5) Build daily digest
    breached = [r for r in per_budget if not r["IsAdherent"]]
    breached.sort(key=lambda r: r["VariancePct"], reverse=True)
    approaching.sort(key=lambda r: r["DaysToBreach"] or 0)

    severity = "info"
    if adherence_score < 60 or any(r["AnomalyCorrelated"] for r in breached):
        severity = "high"
    elif adherence_score < 85 or breached:
        severity = "medium"

    summary = {
        "AlertName": "FinOps daily budget performance digest",
        "severity": severity,
        "GeneratedAt": now_iso,
        "AdherenceScore": adherence_score,
        "ActiveBudgets": active_count,
        "AdherentCount": adherent_count,
        "BreachedCount": len(breached),
        "ApproachingBreachCount": len(approaching),
        "AnomalyActiveThisMonth": anomaly_active,
        "ActiveAnomalies": anomaly_count,
        "TopBreaches": [_top_row(r) for r in breached[:10]],
        "TopApproaching": [_top_row(r) for r in approaching[:10]],
    }
    if errors:
        summary["Errors"] = errors[:20]

    logger.info(json.dumps(summary, default=str))

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="FinOps: Daily budget performance digest",
        Message=json.dumps(summary, default=str, indent=2),
    )
    return {"status": "ok", "active_budgets": active_count, "adherence_score": adherence_score}


def _process_budget(
    budget: dict,
    today: dt.date,
    date_iso: str,
    now_iso: str,
    anomaly_active: bool,
    anomaly_count: int,
) -> dict:
    name = budget["BudgetName"]
    time_unit = budget["TimeUnit"]
    limit_amount = float(budget["BudgetLimit"]["Amount"])
    spend = budget.get("CalculatedSpend") or {}
    actual = float((spend.get("ActualSpend") or {}).get("Amount", 0) or 0)
    forecast = float((spend.get("ForecastedSpend") or {}).get("Amount", 0) or 0)

    period_start, next_period_start = _period_bounds(time_unit, today)
    days_elapsed = max(1, (today - period_start).days)
    days_in_period = (next_period_start - period_start).days

    variance_pct = round(100.0 * (actual - limit_amount) / max(limit_amount, 0.01), 2)
    forecast_variance_pct = round(100.0 * (forecast - limit_amount) / max(limit_amount, 0.01), 2)
    is_adherent = actual <= limit_amount

    # Days-to-breach: how many more days at current burn rate before we hit the limit
    days_to_breach: float | None = None
    if actual > 0:
        daily_burn = actual / days_elapsed
        if daily_burn > 0:
            remaining_budget = limit_amount - actual
            if remaining_budget > 0:
                days_to_breach = round(remaining_budget / daily_burn, 1)
            else:
                days_to_breach = 0.0  # already breached

    # Per-budget metrics
    dim = [{"Name": "Budget", "Value": name}]
    _publish_metric("VariancePct", variance_pct, dimensions=dim)
    _publish_metric("ForecastVariancePct", forecast_variance_pct, dimensions=dim)
    if days_to_breach is not None:
        _publish_metric("BurnRateDaysToBreach", days_to_breach, dimensions=dim)

    # Anomaly correlation: budget breached AND there's an active anomaly = "investigate"
    anomaly_correlated = (not is_adherent) and anomaly_active

    # STATE row
    state_row = {
        "PK": f"BUDGET#{name}",
        "SK": "STATE",
        "BudgetName": name,
        "TimeUnit": time_unit,
        "LimitAmount": _to_decimal(limit_amount),
        "ActualSpend": _to_decimal(actual),
        "ForecastedSpend": _to_decimal(forecast),
        "VariancePct": _to_decimal(variance_pct),
        "ForecastVariancePct": _to_decimal(forecast_variance_pct),
        "DaysToBreach": _to_decimal(days_to_breach) if days_to_breach is not None else None,
        "DaysElapsed": days_elapsed,
        "DaysInPeriod": days_in_period,
        "IsAdherent": is_adherent,
        "AnomalyCorrelated": anomaly_correlated,
        "AnomalyCountInPeriod": anomaly_count,
        "LastEvaluatedAt": now_iso,
        "ExpireAt": _epoch(STATE_TTL_DAYS),
    }
    _TABLE.put_item(Item={k: v for k, v in state_row.items() if v is not None})

    # SNAPSHOT row (daily trend, 13-month TTL)
    snapshot_row = {
        "PK": f"BUDGET#{name}",
        "SK": f"SNAPSHOT#{date_iso}",
        "Date": date_iso,
        "LimitAmount": _to_decimal(limit_amount),
        "ActualSpend": _to_decimal(actual),
        "ForecastedSpend": _to_decimal(forecast),
        "VariancePct": _to_decimal(variance_pct),
        "DaysToBreach": _to_decimal(days_to_breach) if days_to_breach is not None else None,
        "IsAdherent": is_adherent,
        "ExpireAt": _epoch(SNAPSHOT_TTL_DAYS),
    }
    _TABLE.put_item(Item={k: v for k, v in snapshot_row.items() if v is not None})

    return {
        "Name": name,
        "TimeUnit": time_unit,
        "LimitAmount": limit_amount,
        "ActualSpend": actual,
        "ForecastedSpend": forecast,
        "VariancePct": variance_pct,
        "ForecastVariancePct": forecast_variance_pct,
        "DaysToBreach": days_to_breach,
        "DaysElapsed": days_elapsed,
        "DaysInPeriod": days_in_period,
        "IsAdherent": is_adherent,
        "AnomalyCorrelated": anomaly_correlated,
    }


def _top_row(r: dict) -> dict:
    return {
        "Budget": r["Name"],
        "TimeUnit": r["TimeUnit"],
        "LimitAmount": r["LimitAmount"],
        "ActualSpend": r["ActualSpend"],
        "ForecastedSpend": r["ForecastedSpend"],
        "VariancePct": r["VariancePct"],
        "DaysToBreach": r["DaysToBreach"],
        "AnomalyCorrelated": r["AnomalyCorrelated"],
    }

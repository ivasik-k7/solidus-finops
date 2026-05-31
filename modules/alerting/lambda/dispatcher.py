"""
Multi-channel event dispatcher.

Subscribes to the events SNS topic. For each incoming message:

  1. Parse + normalize the payload (severity, fingerprint, fields)
  2. Check the dedup cache (DDB) — if seen in window, suppress
  3. For each configured channel where event.severity >= channel.min_severity:
       dispatch via the channel-specific adapter (slack/teams/pagerduty/etc.)
  4. Write an AUDIT row to DDB with per-channel outcomes
  5. Emit CloudWatch metrics: DispatchedCount / SuppressedCount / FailedCount

Severity ordering (ascending):
    info < low < medium < high < critical

The module's Terraform passes the channel manifest as a JSON env var
(CHANNEL_MANIFEST). Each channel's secret is resolved at runtime via
Secrets Manager (cached per warm container).
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import logging
import os
import uuid
from typing import Any

import boto3

import channels as channel_adapters

logger = logging.getLogger()
logger.setLevel(logging.INFO)

CHANNEL_MANIFEST = json.loads(os.environ.get("CHANNEL_MANIFEST", "{}"))
DEDUP_ENABLED = os.environ.get("DEDUP_ENABLED", "true").lower() == "true"
DEDUP_WINDOW_MINS = int(os.environ.get("DEDUP_WINDOW_MINS", "60"))
DEDUP_FINGERPRINT_FIELDS = json.loads(
    os.environ.get("DEDUP_FINGERPRINT", '["AlertName", "severity", "ResourceId"]')
)
AUDIT_ENABLED = os.environ.get("AUDIT_ENABLED", "true").lower() == "true"
AUDIT_RETENTION_DAYS = int(os.environ.get("AUDIT_RETENTION_DAYS", "365"))
EVENTS_TABLE_NAME = os.environ.get("EVENTS_TABLE_NAME", "")
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FinOps/Alerting")

SEVERITY_ORDER = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}

cw = boto3.client("cloudwatch")
secrets = boto3.client("secretsmanager")
sqs = boto3.client("sqs")
ddb = boto3.resource("dynamodb") if EVENTS_TABLE_NAME else None
_table = ddb.Table(EVENTS_TABLE_NAME) if ddb else None

_secret_cache: dict[str, str] = {}


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------


def handler(event, context):
    """SNS handler. SNS delivers one or more Records to Lambda."""
    records = event.get("Records", []) or []
    logger.info("Received %d SNS record(s)", len(records))

    dispatched = 0
    suppressed = 0
    failed = 0

    for record in records:
        try:
            outcome = _process_record(record)
            dispatched += outcome["dispatched"]
            suppressed += outcome["suppressed"]
            failed += outcome["failed"]
        except Exception:
            logger.exception("Failed to process SNS record")
            failed += 1

    _publish_metrics(dispatched, suppressed, failed)
    return {"dispatched": dispatched, "suppressed": suppressed, "failed": failed}


def _process_record(record: dict) -> dict[str, int]:
    sns = record.get("Sns", {})
    subject = sns.get("Subject") or "FinOps Alert"
    message_raw = sns.get("Message", "") or ""
    timestamp = sns.get("Timestamp") or _now().isoformat()
    msg_id = sns.get("MessageId") or str(uuid.uuid4())

    parsed = _try_parse_json(message_raw)
    severity = _infer_severity(subject, parsed if isinstance(parsed, dict) else {})

    event = {
        "MessageId": msg_id,
        "Subject": subject,
        "Severity": severity,
        "Timestamp": timestamp,
        "MessageRaw": message_raw,
        "Parsed": parsed if isinstance(parsed, dict) else None,
    }

    # Deduplication check
    fingerprint = _fingerprint(event)
    if DEDUP_ENABLED and _is_duplicate(fingerprint):
        logger.info(
            "Suppressing duplicate (fingerprint=%s subject=%s)", fingerprint, subject
        )
        _audit(event, fingerprint, suppressed=True, deliveries=[])
        return {"dispatched": 0, "suppressed": 1, "failed": 0}

    # Mark fingerprint as seen
    if DEDUP_ENABLED:
        _mark_seen(fingerprint)

    # Filter channels by min_severity and dispatch
    deliveries = _dispatch_all(event)
    dispatched_count = sum(1 for d in deliveries if d["ok"])
    failed_count = sum(1 for d in deliveries if not d["ok"])

    _audit(event, fingerprint, suppressed=False, deliveries=deliveries)
    return {"dispatched": dispatched_count, "suppressed": 0, "failed": failed_count}


# ---------------------------------------------------------------------------
# Severity inference + fingerprint
# ---------------------------------------------------------------------------


def _infer_severity(subject: str, parsed: dict) -> str:
    """Normalise to one of: info, low, medium, high, critical.

    Priority order: explicit `severity` field in payload, then subject heuristics."""
    explicit = parsed.get("severity") if isinstance(parsed, dict) else None
    if isinstance(explicit, str) and explicit.lower() in SEVERITY_ORDER:
        return explicit.lower()

    subj = (subject or "").lower()
    if any(k in subj for k in ("critical", "page", "incident", "outage")):
        return "critical"
    if any(
        k in subj
        for k in ("error", "alarm", "exceeded", "anomaly", "high impact", "breach")
    ):
        return "high"
    if any(k in subj for k in ("warning", "forecast", "approaching", "drift")):
        return "medium"
    if any(k in subj for k in ("report", "digest", "weekly", "coverage", "summary")):
        return "info"
    return "info"


def _fingerprint(event: dict) -> str:
    """Compute a stable hash over configured fields (defaults: AlertName +
    severity + ResourceId from the parsed payload, plus the subject)."""
    parsed = event.get("Parsed") or {}
    parts: list[str] = [event["Subject"], event["Severity"]]
    for f in DEDUP_FINGERPRINT_FIELDS:
        v = parsed.get(f)
        parts.append(str(v) if v is not None else "")
    raw = "|".join(parts)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


# ---------------------------------------------------------------------------
# DDB dedup cache + audit
# ---------------------------------------------------------------------------


def _is_duplicate(fingerprint: str) -> bool:
    if not _table:
        return False
    resp = _table.get_item(Key={"PK": f"DEDUP#{fingerprint}"})
    return "Item" in resp


def _mark_seen(fingerprint: str):
    if not _table:
        return
    _table.put_item(
        Item={
            "PK": f"DEDUP#{fingerprint}",
            "SeenAt": _now().isoformat(),
            "ExpireAt": int(
                (_now() + dt.timedelta(minutes=DEDUP_WINDOW_MINS)).timestamp()
            ),
        }
    )


def _audit(event: dict, fingerprint: str, *, suppressed: bool, deliveries: list[dict]):
    if not AUDIT_ENABLED or not _table:
        return
    now_iso = _now().isoformat()
    _table.put_item(
        Item={
            "PK": f"AUDIT#{now_iso}-{event['MessageId']}",
            "Subject": event["Subject"],
            "Severity": event["Severity"],
            "Fingerprint": fingerprint,
            "Suppressed": suppressed,
            "Deliveries": deliveries,
            "AuditedAt": now_iso,
            "ExpireAt": int(
                (_now() + dt.timedelta(days=AUDIT_RETENTION_DAYS)).timestamp()
            ),
        }
    )


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------


def _dispatch_all(event: dict) -> list[dict]:
    deliveries: list[dict] = []
    event_severity_score = SEVERITY_ORDER.get(event["Severity"], 0)

    for ch_type, items in CHANNEL_MANIFEST.items():
        if not items:
            continue
        adapter = channel_adapters.get_adapter(ch_type)
        if adapter is None:
            logger.warning("Unknown channel type: %s — skipping", ch_type)
            continue
        for ch in items:
            min_sev = ch.get("min_severity", "info")
            if event_severity_score < SEVERITY_ORDER.get(min_sev, 0):
                deliveries.append(
                    {
                        "type": ch_type,
                        "label": ch.get("label"),
                        "ok": True,
                        "skipped": "below-min-severity",
                    }
                )
                continue
            try:
                detail = adapter(ch, event, _resolve_secret, sqs)
                deliveries.append(
                    {
                        "type": ch_type,
                        "label": ch.get("label"),
                        "ok": True,
                        "detail": detail,
                    }
                )
            except Exception as e:
                logger.exception(
                    "Channel %s/%s delivery failed", ch_type, ch.get("label")
                )
                deliveries.append(
                    {
                        "type": ch_type,
                        "label": ch.get("label"),
                        "ok": False,
                        "error": str(e)[:200],
                    }
                )

    return deliveries


# ---------------------------------------------------------------------------
# Secret resolution (cached per warm container)
# ---------------------------------------------------------------------------


def _resolve_secret(arn: str) -> str:
    if not arn:
        return ""
    if arn in _secret_cache:
        return _secret_cache[arn]
    resp = secrets.get_secret_value(SecretId=arn)
    val = (resp.get("SecretString") or "").strip()
    _secret_cache[arn] = val
    return val


# ---------------------------------------------------------------------------
# CloudWatch metrics
# ---------------------------------------------------------------------------


def _publish_metrics(dispatched: int, suppressed: int, failed: int):
    cw.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": "DispatchedCount",
                "Value": float(dispatched),
                "Unit": "Count",
            },
            {
                "MetricName": "SuppressedCount",
                "Value": float(suppressed),
                "Unit": "Count",
            },
            {"MetricName": "FailedCount", "Value": float(failed), "Unit": "Count"},
        ],
    )


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _try_parse_json(s: str) -> Any:
    if not s:
        return None
    try:
        return json.loads(s)
    except (json.JSONDecodeError, TypeError):
        return None

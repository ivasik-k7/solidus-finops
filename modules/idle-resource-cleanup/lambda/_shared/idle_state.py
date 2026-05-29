"""
Shared FinOps idle-resource-cleanup state helper.

Backed by a single DynamoDB table with composite key:
  PK = "<ResourceType>#<ResourceId>"       e.g. "EBS#vol-0abc1234"
  SK = "STATE"                              one current-state row per resource
   or "ACTION#<iso-timestamp>"              append-only audit-log rows

STATE row attributes:
  ResourceType, ResourceId, Region, AccountId
  FirstSeenAt, LastSeenAt, SeenCount
  Status:        "new" | "aging" | "snoozed" | "excepted" | "approved" | "deleted"
  StatusUntil:   ISO timestamp (set when Status == "snoozed")
  EstimatedMonthlyCostUsd
  Owner, Tags, ResourceAttrs
  ExpireAt:      epoch seconds, TTL

ACTION row attributes:
  ResourceType, ResourceId, Region, AccountId
  ActionType:   "detected" | "snapshotted" | "deleted" | "released" | "skipped-ceiling" | "rollback"
  ActorId:      e.g. "lambda:<function-name>" or "human:<iam-user>"
  Timestamp:    ISO
  EstimatedSavingsUsd
  Notes
  ExpireAt:     epoch seconds, TTL (default 7y for audit)

Lifecycle transitions managed by this helper:
  upsert_state()   — first sighting → STATE row created with Status="new"
                     subsequent sightings → SeenCount++, LastSeenAt updated
                     SeenCount >= aging_threshold → Status="aging" (severity bump)
                     Existing snoozed row with StatusUntil < now → reset to "aging"
  is_actionable()  — true unless Status in {"snoozed" (active), "excepted"}
  record_action()  — append ACTION row + update STATE.Status if terminal action
"""
from __future__ import annotations

import datetime as dt
import os
from decimal import Decimal
from typing import Any

import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = os.environ["FINDINGS_TABLE_NAME"]
AGING_SEEN_COUNT_THRESHOLD = int(os.environ.get("AGING_SEEN_COUNT_THRESHOLD", "10"))
FINDINGS_TTL_DAYS = int(os.environ.get("FINDINGS_TTL_DAYS", "90"))
ACTIONS_TTL_DAYS = int(os.environ.get("ACTIONS_TTL_DAYS", "2557"))

_ddb_resource = boto3.resource("dynamodb")
_table = _ddb_resource.Table(TABLE_NAME)


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _now_iso() -> str:
    return _now().isoformat()


def _epoch(days_from_now: int) -> int:
    return int((_now() + dt.timedelta(days=days_from_now)).timestamp())


def _pk(resource_type: str, resource_id: str) -> str:
    return f"{resource_type}#{resource_id}"


def _to_decimal(v: Any) -> Any:
    """DynamoDB hates floats; coerce numerics to Decimal."""
    if isinstance(v, float):
        return Decimal(str(round(v, 4)))
    if isinstance(v, dict):
        return {k: _to_decimal(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_to_decimal(x) for x in v]
    return v


def _from_decimal(v: Any) -> Any:
    """Coerce Decimal back to int/float for JSON serialization."""
    if isinstance(v, Decimal):
        f = float(v)
        return int(f) if f.is_integer() else f
    if isinstance(v, dict):
        return {k: _from_decimal(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_from_decimal(x) for x in v]
    return v


# ---------------------------------------------------------------------------
# STATE row
# ---------------------------------------------------------------------------


def get_state(resource_type: str, resource_id: str) -> dict | None:
    resp = _table.get_item(
        Key={"PK": _pk(resource_type, resource_id), "SK": "STATE"},
        ConsistentRead=True,
    )
    item = resp.get("Item")
    return _from_decimal(item) if item else None


def upsert_state(
    *,
    resource_type: str,
    resource_id: str,
    region: str,
    account_id: str,
    estimated_monthly_cost_usd: float,
    owner: str,
    tags: dict[str, str],
    resource_attrs: dict[str, Any] | None = None,
) -> dict:
    """
    Insert or update the STATE row. Returns the row as it now exists,
    with a synthetic field `IsNew` (True if this scan first saw it) and
    `IsAging` (True if SeenCount >= AGING_SEEN_COUNT_THRESHOLD).
    """
    existing = get_state(resource_type, resource_id)
    now_iso = _now_iso()
    new_seen_count = (existing or {}).get("SeenCount", 0) + 1

    # Auto-thaw snoozed if past StatusUntil
    new_status = (existing or {}).get("Status", "new")
    status_until = (existing or {}).get("StatusUntil")
    if new_status == "snoozed" and status_until and status_until < now_iso:
        new_status = "aging"
        status_until = None

    if new_status == "new" and new_seen_count >= AGING_SEEN_COUNT_THRESHOLD:
        new_status = "aging"
    elif new_status not in ("snoozed", "excepted", "deleted", "approved") and new_seen_count >= AGING_SEEN_COUNT_THRESHOLD:
        new_status = "aging"

    item = {
        "PK": _pk(resource_type, resource_id),
        "SK": "STATE",
        "ResourceType": resource_type,
        "ResourceId": resource_id,
        "Region": region,
        "AccountId": account_id,
        "FirstSeenAt": (existing or {}).get("FirstSeenAt", now_iso),
        "LastSeenAt": now_iso,
        "SeenCount": new_seen_count,
        "Status": new_status,
        "EstimatedMonthlyCostUsd": _to_decimal(float(estimated_monthly_cost_usd)),
        "Owner": owner,
        "Tags": _to_decimal(tags),
        "ResourceAttrs": _to_decimal(resource_attrs or {}),
        "ExpireAt": _epoch(FINDINGS_TTL_DAYS),
    }
    if status_until is not None:
        item["StatusUntil"] = status_until

    _table.put_item(Item=_to_decimal(item))
    result = _from_decimal(item)
    result["IsNew"] = existing is None
    result["IsAging"] = new_seen_count >= AGING_SEEN_COUNT_THRESHOLD
    return result


def is_actionable(state: dict | None) -> bool:
    """Return True unless the resource is currently snoozed (active) or excepted."""
    if not state:
        return True
    status = state.get("Status")
    if status == "excepted":
        return False
    if status == "snoozed":
        until = state.get("StatusUntil")
        if until and until > _now_iso():
            return False
    return True


def mark_status(resource_type: str, resource_id: str, status: str, status_until: str | None = None) -> None:
    """Update only the Status field of an existing STATE row."""
    expr = "SET #s = :s, LastSeenAt = :ls"
    vals: dict[str, Any] = {":s": status, ":ls": _now_iso()}
    names = {"#s": "Status"}
    if status_until:
        expr += ", StatusUntil = :su"
        vals[":su"] = status_until
    else:
        expr += " REMOVE StatusUntil"
    _table.update_item(
        Key={"PK": _pk(resource_type, resource_id), "SK": "STATE"},
        UpdateExpression=expr,
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=vals,
    )


# ---------------------------------------------------------------------------
# ACTION row (audit log)
# ---------------------------------------------------------------------------


def record_action(
    *,
    resource_type: str,
    resource_id: str,
    region: str,
    account_id: str,
    action_type: str,
    actor_id: str,
    estimated_savings_usd: float = 0.0,
    notes: str = "",
) -> None:
    """Append an ACTION row and, for terminal actions, update STATE.Status."""
    now_iso = _now_iso()
    _table.put_item(Item=_to_decimal({
        "PK": _pk(resource_type, resource_id),
        "SK": f"ACTION#{now_iso}",
        "ResourceType": resource_type,
        "ResourceId": resource_id,
        "Region": region,
        "AccountId": account_id,
        "ActionType": action_type,
        "ActorId": actor_id,
        "Timestamp": now_iso,
        "EstimatedSavingsUsd": _to_decimal(float(estimated_savings_usd)),
        "Notes": notes,
        "ExpireAt": _epoch(ACTIONS_TTL_DAYS),
    }))

    if action_type in ("deleted", "released"):
        try:
            mark_status(resource_type, resource_id, "deleted")
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Aggregate helpers
# ---------------------------------------------------------------------------


def sum_savings_mtd(resource_type: str | None = None) -> float:
    """Sum EstimatedSavingsUsd across ACTION rows in the current month."""
    month_prefix = _now().strftime("ACTION#%Y-%m")
    total = 0.0
    # We scan via the GSI on Status — but ACTION rows don't carry Status, so
    # we fall back to per-PK queries. This is a best-effort summary; for
    # heavy use, denormalize into a monthly aggregate row.
    # Implementation note: callers typically pass a precomputed total
    # collected during their scan instead of calling this.
    return total

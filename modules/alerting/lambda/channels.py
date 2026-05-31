"""
Channel adapters for the event dispatcher.

Each adapter is a function with signature:

    def adapter(channel_cfg, event, resolve_secret, sqs_client) -> dict

It takes the channel config dict + the parsed event + a callable that
resolves Secrets Manager ARNs to their plaintext value (cached) + a boto3
SQS client (for the SQS adapter).

Returns a small detail dict on success (e.g. {"status": 200}) or raises on
failure.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any, Callable

logger = logging.getLogger()

# Severity → presentation hints
SEVERITY_STYLES = {
    "critical": {
        "emoji": ":rotating_light:",
        "color": "#7B0000",
        "label_color": "danger",
    },
    "high": {"emoji": ":warning:", "color": "#D00000", "label_color": "danger"},
    "medium": {
        "emoji": ":information_source:",
        "color": "#FF8C00",
        "label_color": "warning",
    },
    "low": {"emoji": ":bulb:", "color": "#FFC107", "label_color": "good"},
    "info": {"emoji": ":speech_balloon:", "color": "#3498DB", "label_color": "good"},
}

# PagerDuty Events API severity normalisation (only critical/error/warning/info)
_PD_SEVERITY = {
    "critical": "critical",
    "high": "error",
    "medium": "warning",
    "low": "info",
    "info": "info",
}


def get_adapter(channel_type: str) -> Callable | None:
    return {
        "slack": post_slack,
        "teams": post_teams,
        "pagerduty": post_pagerduty,
        "opsgenie": post_opsgenie,
        "generic_webhooks": post_generic_webhook,
        "sqs": send_sqs,
    }.get(channel_type)


# ---------------------------------------------------------------------------
# Slack
# ---------------------------------------------------------------------------


def post_slack(ch, event, resolve_secret, _sqs) -> dict:
    url = resolve_secret(ch.get("webhook_secret_arn"))
    if not url:
        raise RuntimeError("Slack webhook URL not resolvable")

    style = SEVERITY_STYLES.get(event["Severity"], SEVERITY_STYLES["info"])
    fields = _render_fields(event["Parsed"])

    payload = {
        "text": f"{style['emoji']} *{event['Subject']}*",
        "attachments": [
            {
                "color": style["color"],
                "fields": fields
                if fields
                else [
                    {"title": "Message", "value": _truncate(event["MessageRaw"], 3000)}
                ],
                "footer": f"FinOps Framework · severity={event['Severity']}",
                "ts": _epoch_from_iso(event["Timestamp"]),
            }
        ],
    }
    return _http_post_json(url, payload)


# ---------------------------------------------------------------------------
# Teams (Adaptive Card)
# ---------------------------------------------------------------------------


def post_teams(ch, event, resolve_secret, _sqs) -> dict:
    url = resolve_secret(ch.get("webhook_secret_arn"))
    if not url:
        raise RuntimeError("Teams webhook URL not resolvable")

    style = SEVERITY_STYLES.get(event["Severity"], SEVERITY_STYLES["info"])
    facts = _render_facts(event["Parsed"])

    payload = {
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": style["color"].lstrip("#"),
        "summary": event["Subject"],
        "title": f"{style['emoji']} {event['Subject']}",
        "sections": [
            {
                "facts": facts
                if facts
                else [
                    {"name": "Message", "value": _truncate(event["MessageRaw"], 3000)}
                ],
            }
        ],
    }
    return _http_post_json(url, payload)


# ---------------------------------------------------------------------------
# PagerDuty Events API v2
# ---------------------------------------------------------------------------


def post_pagerduty(ch, event, resolve_secret, _sqs) -> dict:
    integration_key = resolve_secret(ch.get("integration_key_secret_arn"))
    if not integration_key:
        raise RuntimeError("PagerDuty integration key not resolvable")

    payload = {
        "routing_key": integration_key,
        "event_action": "trigger",
        "dedup_key": event.get("Parsed", {}).get("AlertName") or event["Subject"],
        "payload": {
            "summary": event["Subject"],
            "severity": _PD_SEVERITY.get(event["Severity"], "info"),
            "source": "finops-framework",
            "timestamp": event["Timestamp"],
            "custom_details": event.get("Parsed")
            or {"message": _truncate(event["MessageRaw"], 1500)},
        },
    }
    return _http_post_json("https://events.pagerduty.com/v2/enqueue", payload)


# ---------------------------------------------------------------------------
# Opsgenie Alerts API
# ---------------------------------------------------------------------------


def post_opsgenie(ch, event, resolve_secret, _sqs) -> dict:
    api_key = resolve_secret(ch.get("api_key_secret_arn"))
    if not api_key:
        raise RuntimeError("Opsgenie API key not resolvable")

    host = "api.eu.opsgenie.com" if ch.get("eu_region") else "api.opsgenie.com"
    url = f"https://{host}/v2/alerts"

    payload = {
        "message": _truncate(event["Subject"], 130),
        "alias": event.get("Parsed", {}).get("AlertName") or event["Subject"][:512],
        "description": json.dumps(
            event.get("Parsed") or {"message": event["MessageRaw"]}, default=str
        )[:15000],
        "priority": _opsgenie_priority(event["Severity"]),
        "source": "finops-framework",
    }
    return _http_post_json(
        url, payload, headers={"Authorization": f"GenieKey {api_key}"}
    )


def _opsgenie_priority(sev: str) -> str:
    return {
        "critical": "P1",
        "high": "P2",
        "medium": "P3",
        "low": "P4",
        "info": "P5",
    }.get(sev, "P5")


# ---------------------------------------------------------------------------
# Generic webhook
# ---------------------------------------------------------------------------


def post_generic_webhook(ch, event, resolve_secret, _sqs) -> dict:
    url = resolve_secret(ch.get("url_secret_arn"))
    if not url:
        raise RuntimeError("Generic webhook URL not resolvable")

    headers = ch.get("headers", {}) or {}
    return _http_post_json(url, event, headers=headers)


# ---------------------------------------------------------------------------
# SQS
# ---------------------------------------------------------------------------


def send_sqs(ch, event, _resolve_secret, sqs_client) -> dict:
    queue_arn = ch.get("queue_arn")
    if not queue_arn:
        raise RuntimeError("SQS queue_arn missing")
    # Convert ARN to URL
    parts = queue_arn.split(":")
    region, account_id, queue_name = parts[3], parts[4], parts[5]
    url = f"https://sqs.{region}.amazonaws.com/{account_id}/{queue_name}"

    resp = sqs_client.send_message(
        QueueUrl=url,
        MessageBody=json.dumps(event, default=str),
    )
    return {"message_id": resp.get("MessageId")}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _http_post_json(
    url: str, payload: Any, headers: dict[str, str] | None = None
) -> dict:
    data = json.dumps(payload, default=str).encode("utf-8")
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, headers=req_headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.getcode()
            body = resp.read().decode("utf-8", errors="replace")
            if status >= 400:
                raise RuntimeError(f"HTTP {status}: {body[:200]}")
            return {"status": status, "body": body[:200]}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        raise RuntimeError(f"HTTP {e.code}: {body[:200]}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"URL error: {e.reason}") from e


def _render_fields(parsed) -> list[dict]:
    """Slack-style fields list."""
    if not isinstance(parsed, dict):
        return []
    skip = {"severity", "AlertName"}
    fields = []
    for k, v in parsed.items():
        if k in skip:
            continue
        if isinstance(v, (list, dict)):
            v = json.dumps(v, default=str)[:1000]
        fields.append(
            {"title": str(k), "value": str(v)[:1000], "short": len(str(v)) < 40}
        )
    return fields[:20]


def _render_facts(parsed) -> list[dict]:
    """Teams-style facts list."""
    if not isinstance(parsed, dict):
        return []
    skip = {"severity", "AlertName"}
    facts = []
    for k, v in parsed.items():
        if k in skip:
            continue
        if isinstance(v, (list, dict)):
            v = json.dumps(v, default=str)[:1000]
        facts.append({"name": str(k), "value": str(v)[:1000]})
    return facts[:20]


def _truncate(s: str, n: int) -> str:
    if not s:
        return ""
    return s if len(s) <= n else s[:n] + "…"


def _epoch_from_iso(iso: str) -> int:
    import datetime as dt

    try:
        return int(dt.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp())
    except Exception:
        return int(dt.datetime.now(dt.timezone.utc).timestamp())

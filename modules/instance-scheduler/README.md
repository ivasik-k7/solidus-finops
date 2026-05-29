# instance-scheduler

A **standalone, reusable** tag-driven start/stop module for AWS EC2, RDS, and Auto Scaling Groups. DDB-backed lifecycle state, override-window honoring, multi-region scanning, action-count blast-radius cap, and a weekly auto-discovery Lambda that proposes scheduling candidates.

**This module is the execution layer; cost reporting is owned by your analytics tool** (Cloudability / CUR). The module emits action counts and DDB ACTION rows with full per-resource provenance — your analytics layer joins those to actual paid prices (including RIs / SPs / EDP discounts), region by region. We deliberately do not estimate dollar values here: a hardcoded rate table is wrong on day one (region-variant, time-variant, ignores discounts).

**Reusable outside the FinOps framework** — no hard dependency on any sibling module. Drop into any Terraform project that needs scheduling.

**Opt-in by tag.** Off at the root by default — Lambdas with `ec2:StopInstances` + `rds:StopDBInstance` + `autoscaling:UpdateAutoScalingGroup` should be an explicit decision.

## Module layout

```
modules/instance-scheduler/
├── main.tf              header only — module is split by concern
├── versions.tf          Terraform + provider version constraints
├── variables.tf         input contract (all variables + validations)
├── outputs.tf           output contract
├── locals.tf            computed locals (env vars, region resolution)
├── data.tf              caller_identity / partition / region data sources
├── iam.tf               scheduler + discovery IAM roles + policies
├── dynamodb.tf          STATE + ACTION single-table
├── sqs.tf               per-Lambda DLQs
├── lambda.tf            Lambdas + log groups + archive_files
├── eventbridge.tf       tick + discovery triggers
├── cloudwatch.tf        alarms + auto-provisioned dashboard
├── lambda/              Python source — packaged at apply time
│   ├── scheduler.py
│   └── discovery.py
├── scripts/
│   └── emergency-start-all.sh   force-start every managed resource (outage tool)
├── docs/
│   └── EDGE_CASES.md    every operational edge case handled
├── CHANGELOG.md         module version history (SemVer)
└── README.md
```

If you're operating the module at scale, **read [docs/EDGE_CASES.md](docs/EDGE_CASES.md) first** — it documents every transitional state, override semantic, multi-region failure mode, spot instance handling, and lifecycle subtlety the module accounts for.

## Standalone usage (outside the FinOps framework)

```hcl
module "scheduler" {
  source = "git::https://github.com/your-org/finops-framework-demo.git//modules/instance-scheduler?ref=v1.0.0"

  name_prefix = "myproject"
  kms_key_arn = aws_kms_key.shared.arn

  # Optional — if omitted, the scheduler skips SNS publishing entirely.
  # Metrics + DDB audit + CloudWatch alarms still work without it.
  # events_topic_arn = aws_sns_topic.alerts.arn

  schedules = {
    office-hours-cet = {
      days     = ["MON", "TUE", "WED", "THU", "FRI"]
      start    = "08:00"
      stop     = "18:00"
      timezone = "Europe/Berlin"
    }
    weekdays-only = {
      days     = ["MON", "TUE", "WED", "THU", "FRI"]
      start    = "00:00"
      stop     = "23:59"
      timezone = "UTC"
    }
  }

  # Resource types — enable only what you need
  enable_ec2           = true
  enable_rds_instances = true
  enable_rds_clusters  = false
  enable_asg           = false

  # Multi-region (empty = home region only)
  scan_regions = ["eu-central-1", "us-east-1"]

  # Safety — caps blast radius if a mis-tag accidentally targets thousands
  max_actions_per_tick = 200

  # Auto-discovery proposes candidates weekly
  enable_discovery = true

  default_tags = { Owner = "platform-team" }
}

# Tag resources to opt them in
resource "aws_instance" "dev_jumphost" {
  # ...
  tags = {
    Schedule = "office-hours-cet"
    Owner    = "alice@example.com"
  }
}
```

That's it — three resources tagged, one module call. The scheduler ticks every 5 minutes; non-prod resources tagged `Schedule=office-hours-cet` run only Mon–Fri 08:00–18:00 Europe/Berlin.

## Tag conventions

| Tag | Required | Purpose |
|---|---|---|
| `Schedule=<name>` | yes (opts the resource in) | References a named schedule in `var.schedules` |
| `FinOpsException=<any>` | optional | Permanent skip — scheduler ignores the resource |
| `ScheduleOverrideUntil=<iso-ts>` | optional | Temporary skip until the UTC ISO timestamp passes (e.g. during an incident) |
| `Owner=<email>` | recommended | Included in the digest payload so chat-notifier can route DMs |

Examples:

```bash
# Tag an EC2 instance to follow office-hours
aws ec2 create-tags --resources i-0abc1234 \
  --tags Key=Schedule,Value=office-hours-cet Key=Owner,Value=jane@example.com

# Temporarily exempt for the next 4 hours (incident in progress)
aws ec2 create-tags --resources i-0abc1234 \
  --tags Key=ScheduleOverrideUntil,Value=2026-06-15T14:00:00Z

# Permanently exempt (production database)
aws ec2 create-tags --resources i-0abc1234 \
  --tags Key=FinOpsException,Value=true
```

## Schedule shape

```hcl
schedules = {
  office-hours-cet = {
    days     = ["MON", "TUE", "WED", "THU", "FRI"]  # required: list of day codes
    start    = "08:00"                              # required: 24h HH:MM
    stop     = "18:00"                              # required: 24h HH:MM
    timezone = "Europe/Berlin"                      # optional, IANA TZ, default "UTC"
  }
  always-off = {
    days  = []          # empty days list — resource stays stopped
    start = "00:00"
    stop  = "00:00"
  }
}
```

The scheduler converts NOW to the schedule's timezone, checks if today's weekday is in `days`, then evaluates `start <= now < stop` (with midnight wrap-around handled).

## Inputs

### Core

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix |
| `events_topic_arn` | string | — | SNS topic for digests + alarms |
| `kms_key_arn` | string | — | CMK for DDB, log groups, Lambda env |
| `log_retention_days` | number | — | CloudWatch log retention |
| `lambda_runtime` | string | — | Python runtime |
| `default_tags` | map(string) | — | Tags applied to every resource |
| `schedules` | map(object) | — | Named schedules (see schema above) |
| `opt_in_tag_key` | string | `"Schedule"` | Tag key opting a resource in |
| `exception_tag_key` | string | `"FinOpsException"` | Tag key excluding a resource permanently |
| `override_until_tag_key` | string | `"ScheduleOverrideUntil"` | Tag holding ISO-UTC skip-until timestamp |

### Resource-type toggles

| Name | Default | Notes |
|---|---|---|
| `enable_ec2` | `true` | EC2 instances |
| `enable_rds_instances` | `true` | RDS DB instances |
| `enable_rds_clusters` | `true` | Aurora / RDS clusters |
| `enable_asg` | `false` | Auto Scaling Groups (scale-to-zero) — intrusive; opt-in |
| `enable_spot_management` | `false` | Manage spot EC2 instances. Off by default — spot stop semantics differ from on-demand and break the spot contract on EBS-backed AMIs. Skipped spot resources emit `ActionSkippedSpot`. |
| `dry_run` | `false` | Preview mode. Scheduler logs and records what it WOULD do but performs no AWS mutations. DDB STATE/ACTION rows still written (with `outcome=dry-run` / `action_type=dry-run-<would-be-action>`); `ActionDryRun` metric counts decisions. Useful for "what would happen at 18:00 CET tonight?" |

### Multi-region + safety

| Name | Default | Description |
|---|---|---|
| `scan_regions` | `[]` | Regions to scan; empty = home region only |
| `tick_schedule` | `"rate(5 minutes)"` | EventBridge schedule expression |
| `max_actions_per_tick` | `200` | Hard cap on mutating actions per tick. Caps blast radius if a misconfiguration targets thousands of resources. Excess resources defer to the next tick. |

### Auto-discovery (Tier 2)

| Name | Default | Description |
|---|---|---|
| `enable_discovery` | `true` | Deploy the weekly candidate-proposal Lambda |
| `discovery_schedule_cron` | `"0 9 ? * SUN *"` | EventBridge cron, UTC |
| `discovery_cpu_threshold_pct` | `5` | Avg CPU below this flags a resource as a candidate |
| `discovery_lookback_days` | `14` | CloudWatch lookback window |

### Retention

| Name | Default | Description |
|---|---|---|
| `state_ttl_days` | `90` | DDB STATE row TTL after last sighting |
| `action_ttl_days` | `2557` | DDB ACTION row TTL (7-year audit) |

## Outputs

| Name | Description |
|---|---|
| `lambda_arn` / `dlq_arn` | Scheduler Lambda + its DLQ |
| `discovery_lambda_arn` / `discovery_dlq_arn` | Auto-discovery Lambda + its DLQ (null if disabled) |
| `state_table_name` / `state_table_arn` | DDB scheduler state table |
| `dashboard_name` | Auto-provisioned CloudWatch dashboard |
| `metric_namespace` | `FinOps/InstanceScheduler` |
| `scan_regions` | Resolved region list |

## DynamoDB schema

```
PK = "<ResourceType>#<ResourceId>"     e.g. "EC2#i-0abc1234" / "RDSCluster#prod-orders" / "ASG#dev-workers"
SK = "STATE"
    ResourceType, ResourceId, Region, AccountId
    ScheduleName, Owner, IsRunning, LastOutcome, LastSeenAt
    ExpireAt — TTL (state_ttl_days, default 90d)

SK = "ACTION#<iso-ts>-<random>"
    ActionType ∈ {started, stopped, failed, skipped-override, skipped-ceiling}
    ScheduleName, ActorId, Notes, Timestamp
    ExpireAt — TTL (action_ttl_days, default 2557d = 7y)
```

Queries you can run against this table:
- **One resource's full history**: `Query` where `PK = "EC2#i-0abc1234"`, sorted by `SK` — gives current state + every action ever taken
- **All actions on a given UTC date** (cheap, indexed): `Query` the `ActionsByDate` GSI where `GSI1PK = "ACTION#2026-05-29"`, sorted by `GSI1SK`
- **Across-date scans**: aggregate `ActionsByDate` queries day-by-day in your reporting job — cheaper than a table scan even for monthly reports

## CloudWatch metrics (namespace `FinOps/InstanceScheduler`)

| Metric | Dimensions | Meaning |
|---|---|---|
| `ActionStarted` | — | Resources started in this tick |
| `ActionStopped` | — | Resources stopped in this tick |
| `ActionSkippedOverride` | — | Skipped due to `ScheduleOverrideUntil` |
| `ActionSkippedCeiling` | — | Skipped due to action ceiling — deferred to next tick |
| `ActionSkippedSpot` | — | EC2 spot instances skipped (set `enable_spot_management=true` to manage) |
| `ActionScaleAmbiguous` | — | ASG scale-up triggered with no FinOpsSavedMin/Desired tags — fell back to 1/1 |
| `ActionDryRun` | — | Decisions taken in dry-run mode (no AWS mutations performed) |
| `ActionFailed` | — | Action attempted but errored |
| `ManagedResourceCount` | `ResourceType` ∈ {EC2, RDSInstance, RDSCluster, ASG} | Current scheduled-resource count of each type |
| `DiscoveryCandidateCount` | `ResourceType` | Auto-discovery: new candidates this week |

## Daily experience (what an owner sees)

**Tuesday 17:45 UTC** — Slack post in `#finops-info`:

> 🟢 instance-scheduler — activity digest
> Stopped 24 resources at 18:00 CET per `office-hours-cet`.
> EC2: 18 stopped. RDS instances: 4. ASGs: 2 scaled to 0.
> Override-skipped: 1 (i-09abc, override until 2026-06-15T14:00Z).
> _For dollar impact, see [Cloudability dashboard →](https://app.cloudability.com)_

**Sunday morning** — Slack post in `#finops-info`:

> 🔍 scheduler discovery — 7 candidates
> The following non-prod resources show <5% avg CPU over 14 days and aren't tagged with Schedule:
> - i-0123 (m5.large, dev) — avg 2.1% CPU — owner: alice@
> - i-4567 (t3.xlarge, nonprod) — avg 0.8% CPU — owner: bob@
> - dev-orders-rds (db.m5.large) — avg DB connections 0.3 — owner: data-platform@
> Recommend adding `Schedule=office-hours-cet`.

## Design notes

- **Cron evaluation is timezone-aware** — `start`/`stop` are interpreted in `schedule.timezone`. `zoneinfo` is in the Python standard library (3.9+), so no extra dependencies.
- **Idempotent ticks** — each tick computes desired state from the schedule + current time, then reconciles. If a tick is missed, the next one corrects drift.
- **ASG scale-to-zero pattern** — on stop, current `MinSize` + `DesiredCapacity` are stashed in `FinOpsSavedMin` / `FinOpsSavedDesired` tags before scaling to 0. On start, the tags are read and the capacity restored, then the tags are deleted.
- **Action ceiling is per tick** — once the scheduler dispatches `max_actions_per_tick` mutations in a single invocation, further resources defer to the next tick (audited as `skipped-ceiling`). This is a blast-radius cap on misconfigurations, not a cost concept. Dollar-value reporting lives in your analytics tool, joined to actual paid prices from CUR.
- **`Schedule` references must exist** — a resource tagged `Schedule=foo` but with no `schedules.foo` entry is logged + skipped + recorded as `unknown-schedule` in DDB. No silent failure.
- **Quiet ticks don't spam** — if a tick has 0 actions, no events-bus digest is published (CloudWatch metrics still emit).
- **Discovery is advisory** — the auto-discovery Lambda never modifies resources; it only publishes proposals. Humans apply the `Schedule=*` tag.

## When you outgrow this module

- **EKS managed node group scheduling** — scale node groups to 0 outside hours
- **ECS service desired-count scheduling** — same pattern as ASG
- **Pre-stop notification window** — 15-min "stopping soon" warning to the events bus before action
- **Slack action-button approval** for prod-tagged resources — requires API Gateway receiver
- **Schedule preview / dry-run mode** — "what would happen tonight at 18:00 CET?" without acting
- **Holiday calendar** — skip stops on public holidays via an external calendar service
- **Per-resource cost annotation on ACTION rows** — if you don't have CUR/Cloudability, the alternative would be an enrichment Lambda that fetches AWS Pricing API rates per region and stamps `EstimatedHourlyCostUSD` on action rows. Out of scope by default — analytics tools already do this better.

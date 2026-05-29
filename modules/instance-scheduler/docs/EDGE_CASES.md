# instance-scheduler — edge cases & how the module handles them

This module operates against live production resources across many regions
on a recurring tick. Every paragraph below is a failure mode someone
operating it at scale will eventually hit. Each one names the cause, the
module's behavior, and the lever you have if you want different behavior.

---

## 1. Schedule definition

### 1.1 Empty `schedules` map
The Lambda still ships, but evaluates zero resources and acts on nothing.
The `schedules_configured` output drops to `0` — wire an alarm on this for
"someone TF-removed all schedules by accident".

### 1.2 Schedule with empty `days = []`
Treated as "never active". The scheduler stops any resources tagged with
that schedule and never starts them. Useful as a "freeze" schedule.

### 1.3 `stop` < `start` (e.g. start 22:00, stop 06:00)
**Wraps midnight.** The active window spans two calendar days. Resources
stay running across the boundary. Implementation: `_desired_running()`
compares hour/minute tuples directly when `start <= stop`, and uses
`current >= start OR current < stop` when `start > stop`.

### 1.4 `start == stop`
Treated as **always active** (24h schedule for the listed days). If you
want "never active", set `days = []` instead.

### 1.5 Invalid timezone string
`zoneinfo.ZoneInfoNotFoundError` is caught and the scheduler falls back to
**UTC** with a `WARN`-level log line including the offending schedule
name. The resource is still evaluated — fail-safe over fail-stop, since
silently skipping a schedule could leave money on the floor.

### 1.6 Tag value not in `schedules`
Resource is skipped with a single `WARN` log per resource per tick. No
metric is published (would dominate cardinality on misconfigured fleets).
This includes the empty-string and whitespace-only cases.

### 1.7 DST transitions
`zoneinfo` resolves automatically. During the "spring forward" hour the
scheduler may see the resource as "should be running" twice (once before
the jump, once after) — idempotency in `_evaluate_resource` makes the
duplicate a no-op. During "fall back", the hour repeats; a start action
fires twice but the second is a no-op against a running instance.

---

## 2. Tag overrides & exceptions

### 2.1 `ScheduleOverrideUntil` in the past
Treated as expired — override has no effect, resource follows its normal
schedule. A `STATE` row update records the override drop so dashboards
show the moment control resumed.

### 2.2 `ScheduleOverrideUntil` malformed
ISO 8601 parse failure → override ignored, scheduler proceeds with normal
schedule, `WARN` log emitted. Fail-safe: a typo shouldn't pin a resource
"on" forever.

### 2.3 `ScheduleOverrideUntil` far in the future (e.g. year 2099)
Honored exactly as written. The DDB STATE row carries `ExpireAt =
override_until`, so the override outlives the default state TTL.

### 2.4 `FinOpsException = true`
Hard skip. Resource is excluded from all evaluation, no action row
written, but a `ManagedResourceCount` metric is still emitted with
dimension `Excluded=true` so dashboards count exempted spend.

---

## 3. Resource-state surprises

### 3.1 EC2 instance in `stopping`, `pending`, `shutting-down`, `terminated`
Scheduler waits — it only acts on `running` or `stopped`. Transitional
states resolve to the next tick (max 5 minutes of dwell). `terminated` and
`shutting-down` resources are removed from the STATE rows by the action
recorder so dashboards stop counting them.

### 3.2 EC2 spot instance
Detected via `InstanceLifecycle == "spot"`. **Stop is not safe for spot**
(spot StopInstances on instance-store-backed AMIs is impossible; on
EBS-backed AMIs it works but interrupts the spot contract). Module
**skips with `ActionSkippedSpot` metric** rather than acting. Override
with `enable_spot_management = true` if you've reviewed the implications.

### 3.3 EC2 instance with `DisableApiStop` / `DisableApiTermination`
StopInstances returns `OperationNotPermitted`. Caught per-resource,
recorded as `ActionFailed` with reason `api_stop_disabled`. Doesn't fail
the tick.

### 3.4 RDS instance in `creating`, `modifying`, `backing-up`, `maintenance`
RDS rejects stop/start during these. Caught per-resource as
`InvalidDBInstanceState`, recorded as `ActionFailed` with the AWS-side
state for triage. Next tick retries.

### 3.5 RDS instance stopped > 7 days
AWS auto-starts RDS after 7 days regardless. Scheduler will then see it
running and stop it again on the next active-window boundary. The DDB
`ACTION` audit captures this dance so the cost story is honest.

### 3.6 RDS with read replicas
Stopping a primary with replicas requires deleting replicas first. AWS
will reject the stop. Module records `ActionFailed` with reason
`has_read_replicas` and **does not delete the replicas** — that's a data
operation the scheduler is not authorized to make.

### 3.7 Aurora cluster mid-failover
`InvalidDBClusterState` caught, recorded, retried next tick.

### 3.8 ASG: scale-to-zero stash conflict
When scaling an ASG to zero, the module writes the previous
`Min`/`Desired` into `FinOpsSavedMin` / `FinOpsSavedDesired` tags on the
ASG. On scale-back-up it reads them. If they're missing (someone deleted
them, ASG was scaled by another actor mid-window), fallback is
`Desired = 1, Min = 1`. A `WARN` log is emitted and the stash-miss is
counted as `ActionScaleAmbiguous` so this can be alerted on.

### 3.9 ASG with active scheduled actions
The module does not interfere with `aws_autoscaling_schedule` resources —
they continue to operate. If both target the same ASG, last-write-wins.
Document the conflict in your README; don't mix the two control planes.

### 3.10 ASG attached to a lifecycle-hook-protected fleet
Scale-down may hang on lifecycle hooks. Module triggers the scale and
moves on; the hook timeout governs eventual completion. Recorded only as
`ActionStopped` from the scheduler's perspective.

---

## 4. Cross-region / cross-account

### 4.1 One region throws (DNS, throttle, ICE error)
The scheduler wraps each region in a `try/except` and emits
`ActionFailed` with `dimension Region=<region>`. **Other regions
continue.** A single region's outage cannot stop scheduling in others.

### 4.2 Empty `scan_regions`
Resolved to `[data.aws_region.current]` at plan time. Safe default — no
"scheduler running but doing nothing because region list is empty".

### 4.3 Region with zero opt-in resources
Scheduler still emits `ManagedResourceCount = 0` for that region, so a
suddenly-empty region (everyone untagged) is visible.

### 4.4 Cross-account scheduling
This module does not assume into other accounts. For multi-account
scheduling, deploy one instance of the module per account from a
delegated pipeline. The DDB `STATE` table is per-account by design — the
blast radius of a misconfigured schedule is one account.

---

## 5. Action ceiling (blast-radius cap)

### 5.1 Ceiling hit mid-tick
Once the scheduler has dispatched `max_actions_per_tick` mutations
(start + stop combined) in a single invocation, every subsequent
resource that would change state is **deferred to the next tick** and
recorded as `skipped-ceiling`. Both starts and stops contribute to the
budget — the ceiling protects against misconfigurations (mass mis-tag,
schedule typo), not against money loss in any direction. Re-evaluates
from zero on the next tick.

### 5.2 Why count, not dollars?
Dollar-denominated ceilings sound safer but lie:
- **Regional variance** — c5.xlarge is $0.170 in us-east-1, $0.272 in
  sa-east-1 (60%+ delta on a single SKU).
- **Time variance** — AWS adjusts list prices; a hardcoded table goes
  stale immediately.
- **Discounts** — RIs, Savings Plans, EDP all change effective price.
  An on-paper-$1000 ceiling might cap on real $400, or real $1800.
- **Wrong primitive** — what the ceiling actually protects against is
  "a mis-tag accidentally targeted 5000 resources". That's a count.

Dollar-value reporting belongs in the analytics layer (Cloudability /
CUR-backed dashboards), which joins resource activity to actual paid
prices. The module emits action counts; the analytics layer answers
"how much did we save?"

### 5.3 Ceiling = 1
Allows exactly one action per tick. Practical effect: "drain mode" —
the scheduler trickles changes through one at a time. Useful for
incident response or very-cautious rollouts.

---

## 6. DynamoDB state lifecycle

### 6.1 STATE row TTL'd while action history remains
Expected. STATE rows expire after `state_ttl_days` (default 90); ACTION
rows live for `action_ttl_days` (default 7 years, audit retention).
Reading per-resource history with no STATE row is normal — it just means
the resource is currently dormant.

### 6.2 Table at provisioned-throughput cap
Module uses PAY_PER_REQUEST. Throughput is on-demand — DDB throttles a
hot partition only, not the table. Hot partition risk is mitigated by
`PK = <ResourceType>#<ResourceId>` — even pathological workloads spread
across PKs.

### 6.3 Cross-region table needed
Not built in. Single-region DDB by default. If you need DR, attach
DDB Global Tables externally — the module's `state_table_arn` output is
the integration point.

---

## 7. Lambda failures

### 7.1 Lambda timeout
Default 300s for scheduler, 600s for discovery. Tune via the module's
`lambda_*_timeout` overrides if you're scanning very large accounts.
On timeout the invocation lands in the DLQ; the next tick re-runs.

### 7.2 IAM permission missing for new resource type
Caught per-resource, `ActionFailed` row with the IAM error text in
`FailureReason`. Doesn't poison the tick.

### 7.3 DLQ filling up
`scheduler_dlq_depth` alarm fires on > 0 visible messages. Investigate
via `aws sqs receive-message` — payload is the original CloudWatch Events
invocation, useful for replay.

### 7.4 Cold-start during dense fleet
First invocation may be slow (boto3 client init × N regions). Mitigations
already in place: clients are module-scope cached, adaptive retries.
If still slow, raise `memory_size` — Lambda CPU scales with memory.

---

## 8. Operational / TF lifecycle

### 8.1 `terraform destroy` on the module
DDB table has `prevent_destroy = true`. **Destroy will error out** —
this is intentional. To actually delete, remove `prevent_destroy` in a
deliberate commit, then destroy. Keeps drift-cleanup scripts from
accidentally wiping audit history.

### 8.2 Renaming `name_prefix`
Forces replacement of nearly everything (Lambdas, DDB, IAM, alarms).
Change with care; the audit trail will be discontinuous across the
rename. Prefer a `moved {}` block over destroy/recreate when feasible.

### 8.3 Schedule schema future migration
The schedule shape (`days` / `start` / `stop` / `timezone`) is the v1
contract. If a future major version changes the shape, resources tagged
with an unrecognised schedule definition fall through case 1.6 and are
skipped with a `WARN`. The module will not silently misinterpret an
old-format schedule as a new one.

### 8.4 Disabling discovery after it was enabled
`enable_discovery = false` removes the discovery Lambda, rule, log
group, and DLQ. The candidate proposals it had written to DDB remain —
they're just no longer being added to.

### 8.5 KMS key rotated
Lambda env-var encryption follows the rotation automatically. No
restart needed. DDB encryption uses the same key — also transparent.
The only thing to watch: if the rotation drops the old key version,
historical CloudWatch Log Group entries become unreadable.

---

## 9. The biggest one: "what if scheduler stops?"

If the scheduler is itself broken — Lambda paused, IAM revoked, account
SCP added — **resources stay in their current state.** Nothing reverts.
Long-stopped instances stay stopped (saving you money but possibly
breaking applications); running instances stay running. There is no
"auto-restore on scheduler outage."

This is intentional: the scheduler is a control loop, not a state
machine. Loss of the controller should not undo prior decisions. If you
need every resource back to "running" during an outage, run the recovery
script [scripts/emergency-start-all.sh](../scripts/emergency-start-all.sh) —
it scans the STATE table and fires the appropriate start API per
resource. Supports `DRY_RUN=true` and `FILTER_REGION=<region>`.

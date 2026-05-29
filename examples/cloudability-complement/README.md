# examples/cloudability-complement

For organizations that already run **Apptio Cloudability** for FinOps analytics, this example deploys only the AWS-native execution + enforcement + audit capabilities Cloudability doesn't provide.

## The split

```
       ╔═══════════════════════════════════════════════╗
       ║         CLOUDABILITY (read-only)              ║
       ║  Dashboards • Business Mappings • Anomaly     ║
       ║  Detection • Rightsizing • Commitment         ║
       ║  Tracking • Cross-cloud rollup • Chargeback   ║
       ╚════════════════════╤══════════════════════════╝
                            │ reads from
                            ▼
       ┌───────────────────────────────────────────────┐
       │   CUR 2.0 + FOCUS in S3                       │
       │   (this framework provisions, both consume)   │
       └───────────────────────────────────────────────┘
                            ▲
                            │
       ╔════════════════════╧══════════════════════════╗
       ║   THIS FRAMEWORK (write + enforce + audit)    ║
       ║                                               ║
       ║   ✅ tag-governance  Config enforcement       ║
       ║   ✅ budgets         AWS Budget Actions       ║
       ║                       (IAM/SCP auto-deny)     ║
       ║   ✅ idle-cleanup    DDB-audited deletion     ║
       ║   ✅ instance-sched  Tag-driven start/stop    ║
       ║   ✅ alerting        Events bus for in-account║
       ║                       AWS signals             ║
       ╚═══════════════════════════════════════════════╝
```

## What's on

| Module | Role | Why on |
|---|---|---|
| `alerting` | Events SNS bus + chat-notifier | Internal events Cloudability doesn't see (Config compliance, tag drift, Lambda errors, Budget Action firings) |
| `cost-data-exports` | CUR 2.0 + FOCUS + Athena | Feeds Cloudability AND gives you in-account Athena for forensic queries |
| `tag-governance` | Required-tag Config rules + tag-drift audit | Enforcement layer Cloudability lacks |
| `budgets` | Polymorphic budgets + AWS Budget Actions | Cloudability budgets are advisory; these can auto-apply IAM deny |
| `idle-resource-cleanup` | 6 resource types, multi-region, DDB audit | Cloudability identifies idle resources but can't act |
| `instance-scheduler` | Tag-driven EC2 start/stop | No Cloudability equivalent |
| `optimization-services` | Compute Optimizer + Cost Optimization Hub | Free; complements Cloudability's rightsizing |

## What's off

| Module | Why off | Cloudability equivalent |
|---|---|---|
| `finops-metrics` | Cloudability dashboards win | Native dashboards + custom views |
| `cost-categories` | Cloudability Business Mappings are easier for finance | Business Mappings GUI |
| `anomaly-detection` | Cloudability's anomaly engine is more sophisticated | Anomaly Detection feature |
| `savings-coverage-reporter` | Cloudability has continuous commitment tracking | RI/SP planning + utilization views |
| `tag-governance.enable_untagged_cost_report` | Cloudability is better at the dollarized tag gap | Tag Explorer report |

## Integration points

### 1. Cloudability reads from your CUR bucket
The `cost_data_bucket_arn` output is what you feed into Cloudability's account-onboarding wizard. Both tools read the same CUR — single source of truth.

### 2. Cloudability writes back into your events bus
Subscribe Cloudability's webhook (or an email distribution Cloudability sends to) to the `events_topic_arn` so cross-cloud Cloudability alerts land in the same Slack channel as in-account ones. One inbox.

### 3. AWS Budget Actions auto-enforce — Cloudability sees the breach happened
When a Budget Action fires (e.g., applies an IAM-deny on sandbox at 100%), the event lands in:
- The framework's events bus → Slack via chat-notifier
- AWS CloudTrail → Cloudability via its CloudTrail ingestion

Both tools tell the same story; only this framework can execute the action.

### 4. Tag-drift events flow only here
Cloudability sees "this resource is missing CostCenter" in its tag-coverage report. This framework sees "someone JUST CHANGED CostCenter on `arn:aws:ec2:.../i-abc123` from `retail-banking` to `tech-shared`" via `aws.tag` EventBridge events — and notifies the FinOps team in real time. The cumulative tag-coverage stays in Cloudability; the audit-grade drift trail stays in this framework's DDB.

## Cost expectation

This deployment is materially cheaper than running the full framework alongside Cloudability:

| Component | Monthly |
|---|---|
| KMS + Secrets Manager + bus + budgets baseline | ~$4 |
| Budgets (~3 paid budgets) | ~$2 |
| DynamoDB (budgets + idle state tables) | <$1 |
| Lambda compute (~4 active Lambdas in this config) | $0 (free tier) |
| CloudWatch (metrics + alarms + dashboards) | ~$1 |
| AWS Config recorder (4-tag rule) | **~$80–150** (largest variable) |
| Athena (forensic queries, ~50/mo) | ~$0.25 |
| **Framework total** | **~$90–160 / mo** |

Plus your Cloudability subscription (separate negotiation).

If AWS Config is **already enabled at the org level** (typical with Control Tower), set `enable_config_recorder = false` in the tag-governance module — drops framework total to **~$10–15/mo**.

## Run

```bash
cd examples/cloudability-complement
terraform init
terraform plan
terraform apply
```

Then in Cloudability's console:
1. **Add AWS Account** → use the `cost_data_bucket_arn` from `terraform output`
2. **Webhook subscription** (optional) → subscribe to `events_topic_arn` so Cloudability alerts land alongside in-account ones
3. **Business Mappings** → define your allocation hierarchy using the tags this framework is now enforcing

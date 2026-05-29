# Tag Governance Patterns

The [tag-governance module](../modules/tag-governance/) handles the things a generic Terraform module can own: required-tag Config rules, tag drift audit, untagged-cost reporting, allocation Resource Groups. This document covers the patterns it **can't** own — usually because they're account-IAM-specific, org-management-specific, or pipeline-specific.

The right mental model is **three layers of tag governance**, ranked by leverage:

```
┌──────────────────────────────────────────────────────────────┐
│  Layer 1: Prevent at creation (highest leverage)             │
│    IAM RequestTag conditions / SCPs / Tag Policies           │
│    → resource creation fails if mandatory tags missing       │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│  Layer 2: Detect after creation (this framework)             │
│    REQUIRED_TAGS Config rule + EventBridge → SNS             │
│    → non-compliant resources surfaced to humans              │
└──────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────┐
│  Layer 3: Quantify the cost of failures (this framework)     │
│    untagged-cost report + tag-health score                   │
│    → "you're leaking $X/month because of bad tagging"        │
└──────────────────────────────────────────────────────────────┘
```

A FinOps program that only has Layer 2 is doing better than most. To be best-practice you want all three.

---

## Layer 1 — Prevent at creation

These are **the highest-leverage controls** but they live outside this framework because:

- They modify IAM/SCP/Service Catalog scopes that are global concerns, not module-local.
- They require coordination with security and platform engineering teams.
- The right pattern depends on whether you use AWS Organizations, Identity Center, or per-account IAM.

### Pattern 1.1 — IAM `RequestTag` deny on critical resource creations

Block `ec2:RunInstances`, `rds:CreateDBInstance`, `s3:CreateBucket`, etc. when mandatory tags are missing from the request:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRunInstancesWithoutFinOpsTags",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "Null": {
          "aws:RequestTag/CostCenter":   "true",
          "aws:RequestTag/BusinessUnit": "true",
          "aws:RequestTag/Application":  "true",
          "aws:RequestTag/Owner":        "true"
        }
      }
    },
    {
      "Sid": "DenyAlterTagsForFinOpsKeys",
      "Effect": "Deny",
      "Action": [
        "ec2:CreateTags",
        "ec2:DeleteTags"
      ],
      "Resource": "*",
      "Condition": {
        "ForAnyValue:StringEquals": {
          "aws:TagKeys": [
            "CostCenter",
            "BusinessUnit",
            "Application"
          ]
        },
        "StringNotEquals": {
          "aws:PrincipalTag/FinOpsRole": "true"
        }
      }
    }
  ]
}
```

The first statement blocks creation without tags. The second blocks anyone (except principals tagged `FinOpsRole=true`) from later mutating allocation tags — which the `aws.tag` drift watcher in this framework would catch, but Deny at the IAM layer is stronger.

Attach as a permission boundary on every workload role, OR as a customer-managed policy attached at the OU level via Identity Center.

### Pattern 1.2 — AWS Organizations Tag Policies

For accounts managed under AWS Organizations, attach a Tag Policy to the OU. Tag Policies don't deny creation but they make non-compliance visible at scale via the Tag Policies report. Useful as a complement to IAM Deny.

```json
{
  "tags": {
    "CostCenter": {
      "tag_key":   { "@@assign": "CostCenter" },
      "tag_value": { "@@assign": ["CC-*"] },
      "enforced_for": { "@@assign": ["ec2:instance", "rds:db", "s3:bucket"] }
    }
  }
}
```

This framework does **not** provision Org Tag Policies (out of scope — handle in your landing-zone workspace). Your org-management workspace can read this framework's `mandatory_tag_keys` output and translate to a Tag Policy.

### Pattern 1.3 — Service Control Policies (org-level deny)

For multi-account organizations, an SCP attached at the OU level provides the strongest preventive control. Same JSON shape as the IAM policy above, but applied via Organizations:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RequireFinOpsTagsOnCreate",
      "Effect": "Deny",
      "Action": ["ec2:RunInstances", "rds:CreateDBInstance"],
      "Resource": "*",
      "Condition": {
        "Null": {
          "aws:RequestTag/CostCenter":  "true",
          "aws:RequestTag/BusinessUnit": "true"
        }
      }
    }
  ]
}
```

SCPs apply to all principals in the OU including root — they are the only mechanism that prevents an admin from creating untagged resources.

### Pattern 1.4 — Provisioning-layer enforcement

If your platform team uses Service Catalog, AWS Proton, Backstage, or an internal IaC pattern repo, the **highest-leverage** place to enforce tagging is there:

- Service Catalog products can require tag parameters at launch.
- Internal Terraform modules can require tag inputs and set `default_tags` at the provider block.
- A pre-commit / pre-merge OPA / Conftest policy can fail any Terraform resource that doesn't include allocation tags.

This is where most mature FinOps practices invest, because it solves the problem **before** it becomes detection work.

---

## Layer 2 — Detect after creation

This is what the tag-governance module provides:

- **Config managed rule `REQUIRED_TAGS`** — runs on every resource change. Non-compliance → EventBridge → events bus.
- **EventBridge `aws.tag Tag Change on Resource`** — watches allocation-critical tag keys for any mutation, audits to the events bus.

There's nothing to add here at the framework level.

---

## Layer 3 — Quantify the gap

Also provided by the module:

- **Weekly untagged-cost report Lambda** — dollarizes the tag gap.
- **`FinOps/TagGovernance/*` CloudWatch metrics** — coverage %, untagged $, health score.
- **CloudWatch alarm on `TotalUntaggedCostUsd`** — fires when the gap exceeds a configurable threshold.

The point of Layer 3 is to give the FinOps lead a number to drive: "our untagged cost was $4 200 last month, target is $1 000". This is **not** the same as "94% of resources are tagged" — a tiny number of expensive untagged resources can blow the cost target while compliance % looks fine.

---

## Anti-patterns

1. **Auto-tagging non-compliant resources with `Owner=unknown` or `CostCenter=unallocated`.** Creates unauditable shadow allocation; this framework deliberately doesn't.
2. **Free-text tag values.** Always use `allowed_values` or a regex pattern. Typos move money to non-existent cost centers and are nearly impossible to catch after the fact.
3. **Mandatory tags > 6.** AWS Config's managed rule accepts 6 per rule. This framework chunks correctly, but each additional rule chunk doubles the eval cost and gives diminishing returns. Pick the 6 that matter; demote the rest to `recommended` in the taxonomy.
4. **Tag changes via shared admin roles.** Drift detection logs the change but the audit trail is useless if a dozen people share the same role. Tag administrative principals with `FinOpsRole` and gate allocation-tag mutations on that principal tag.
5. **Treating tag compliance as a binary.** Use the health score and untagged-cost metrics. A 95%-compliant account can still have 50% of cost in the untagged 5%.

---

## Recommended bootstrap order

If you're starting from zero tag governance:

1. **Week 1**: Deploy the tag-governance module with `enable_untagged_cost_report = false`. Look at the Config rule findings.
2. **Week 2–4**: Backfill tags on the top-50 highest-cost resources. Add `tag_drift_watched_keys` for the allocation set.
3. **Month 2**: Turn on the untagged-cost report. Establish a baseline `untagged_cost_alarm_threshold_usd`. Start the tag-health score conversation with stakeholders.
4. **Month 3**: Implement Layer 1 (IAM RequestTag deny) for at least `ec2:RunInstances` and `rds:CreateDBInstance` in non-prod first, then prod.
5. **Month 6**: Drive `TagHealthScore` ≥ 90 as a steering-committee metric. Add value-validation regexes (custom Config rules) for the highest-value tags.

This sequencing keeps the tightening-the-screws timeline visible to the people whose work it affects.

# Security Policy

Solidus FinOps provisions Lambdas that can stop EC2 / RDS instances,
delete EBS volumes, and read your cost data. A vulnerability in this
framework can directly affect production workloads and finance-grade
audit evidence. We take security reports seriously and prioritise them
above all other work.

## Supported versions

| Version | Supported |
|---|---|
| `0.2.x` | ✅ Active |
| `0.1.x` | ⚠️ Security fixes only |
| `< 0.1.0` | ❌ Unsupported (pre-release) |

Pre-1.0 minor versions may contain breaking changes; pin the module ref
explicitly.

## Reporting a vulnerability

**Do not open a public GitHub issue** for security vulnerabilities.

### Preferred: GitHub Security Advisories (private)

1. Navigate to the
   [Security Advisories page](https://github.com/<org>/<repo>/security/advisories/new)
   for this repository.
2. Click **"Report a vulnerability"**.
3. Fill in the form. GitHub keeps the discussion private until disclosure.

### Alternative: encrypted email

Send a report to **ivan.kovtun@dataart.com** with subject prefix
`[SECURITY] solidus-finops:` followed by a one-line summary.

If you wish to encrypt, request the project maintainer's public GPG key
in your first message and we'll provide it before you share details.

### What to include

- **Affected module(s)** (or "the root composition") and approximate
  version / commit SHA
- **Reproduction steps** — minimal Terraform config or Lambda input that
  triggers the issue
- **Impact** — what an attacker could achieve (IAM escalation, data
  exfiltration, denial of service, financial impact, etc.)
- **Suggested mitigation** if you have one
- **Your name + affiliation** if you'd like credit on the disclosure

## What happens next

| Day | What you can expect |
|---|---|
| 0 | We acknowledge receipt within 48h |
| 1–7 | Triage. We confirm reproduction, assess severity (CVSS v3.1), and assign a CVE if applicable |
| 7–30 | We prepare a fix on a private branch. You'll be invited to review the patch before public disclosure |
| 30–90 | Coordinated disclosure: a release is tagged with the fix, a [GitHub Security Advisory](https://docs.github.com/code-security/security-advisories) is published, and `CHANGELOG.md` notes the fix |

We aim to follow the 90-day disclosure window, but **shorter timelines
are possible for actively exploited issues** or **longer ones for
complex multi-account impact**, by agreement with the reporter.

## Out of scope

The following are **not** security vulnerabilities in this framework:

- **Default `Resource = "*"` in IAM policies for EC2 / RDS / ASG actions.**
  AWS doesn't support resource-level permissions for many of the actions
  the framework needs (`ec2:StopInstances`, `rds:DescribeDBClusters`,
  `autoscaling:UpdateAutoScalingGroup`, etc.). The framework follows AWS
  documentation; tightening these is a Checkov false-positive and is
  documented inline in the IAM files.
- **Customer cost data exposed to the Lambda role.** This is by design —
  the framework's job is to read CUR.
- **Misconfiguration by the consumer** (e.g. wide TFE workspace ACLs,
  shared AWS credentials). Operate the framework following
  [docs/TFE_SETUP.md](docs/TFE_SETUP.md) and
  [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).
- **Behaviour of upstream AWS services.** Report those to AWS via
  https://aws.amazon.com/security/vulnerability-reporting/.

## Hall of fame

We thank the following reporters for responsibly disclosed vulnerabilities:

_(no entries yet — be the first)_

## Auditing this codebase yourself

If you're evaluating Solidus FinOps for a regulated workload, the
following are good starting points:

- [docs/COMPLIANCE_NOTES.md](docs/COMPLIANCE_NOTES.md) — SOX / PCI / GDPR
  / DORA / BCBS 239 mapping
- The framework KMS key policy in [main.tf](main.tf)
- Per-Lambda IAM policies in `modules/*/iam.tf`
- DDB encryption + PITR + `prevent_destroy` settings in
  `modules/*/dynamodb.tf`

For a more comprehensive third-party audit, contact the maintainer to
arrange access to the design rationale documents that don't ship in the
repo.

# Code of Conduct

Solidus FinOps is built and used in contexts where decisions affect real
money, real production workloads, and real auditors. The same care that
goes into the code is expected in how we interact with each other.

## Our standards

Contributors, maintainers, and users are expected to:

- **Engage in good faith.** Assume the other person is trying to make
  the framework better. Read the proposal as written before reacting.
- **Critique code, not people.** "This IAM policy is too broad" is fine.
  "You don't understand IAM" is not.
- **Acknowledge tradeoffs.** Most decisions in this framework
  (off-by-default destructive automation, dollar-value reporting
  deferred to the analytics layer, count-based blast caps) have explicit
  rationale documented in the per-module CHANGELOGs and EDGE_CASES docs.
  Disagree with the rationale, not the existence of the choice.
- **Respect domain expertise.** FinOps practitioners, auditors, security
  reviewers, and SREs all read this code from different angles. A
  reviewer flagging something you didn't consider is doing the project a
  favour.
- **Keep discussion on-topic.** This repo is for the FinOps framework.
  Political, religious, or unrelated personal commentary belongs
  elsewhere.

## Unacceptable behaviour

The following will result in a warning, then a ban from project spaces:

- Personal attacks, name-calling, or hostility toward contributors,
  reviewers, users, or maintainers.
- Sustained disruption of discussions or pull request review.
- Publishing private information of others (email, real name, address,
  employer details) without explicit permission.
- Posting secrets, credentials, or proprietary infrastructure details
  belonging to other organisations.

## Scope

This Code of Conduct applies to all project spaces — GitHub issues, pull
requests, code review comments, project Discussions, project chat
channels — and to public spaces when an individual is representing the
project.

## Reporting

Report incidents to **ivan.kovtun@dataart.com** with subject prefix
`[CoC] solidus-finops:`. Reports are handled confidentially. The
maintainer will acknowledge receipt within 72 hours and decide on a
response within 7 days.

If the maintainer is the subject of the report, escalate to your
employer's compliance contact or the GitHub Trust & Safety team via
https://github.com/contact.

## Enforcement

Maintainers may, in proportion to severity:

1. **Private warning** — first-time, low-severity. Explanation of what
   was off and what's expected going forward.
2. **Public warning + temporary cool-off** — pattern of issues, or
   single significant incident. No project participation for a defined
   period.
3. **Permanent ban** — repeated incidents after warnings, or a single
   incident severe enough to warrant immediate removal.

Enforcement decisions are reviewed by the maintainer and recorded
internally. Banned individuals may appeal in writing after 90 days.

## Acknowledgement

This Code of Conduct draws on the spirit of the
[Contributor Covenant](https://www.contributor-covenant.org/) and on the
operational realities of FinOps engineering. It's deliberately concise so
contributors actually read it.

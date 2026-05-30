# Getting Support

Solidus FinOps is open-source software maintained on volunteer time.
Support is best-effort and channel-dependent.

## Quickest path by question type

| You want to... | Use |
|---|---|
| **Ask "how do I configure X?"** | [GitHub Discussions → Q&A](https://github.com/<org>/<repo>/discussions/categories/q-a) |
| **Report a bug** | [GitHub Issues](https://github.com/<org>/<repo>/issues/new/choose) with the *Bug report* template |
| **Propose a feature** | [GitHub Issues](https://github.com/<org>/<repo>/issues/new/choose) with the *Feature request* template |
| **Report a security vulnerability** | See [SECURITY.md](SECURITY.md) — do NOT use Issues or Discussions |
| **Share what you built with the framework** | [GitHub Discussions → Show and tell](https://github.com/<org>/<repo>/discussions/categories/show-and-tell) |
| **Discuss design / architecture** | [GitHub Discussions → Ideas](https://github.com/<org>/<repo>/discussions/categories/ideas) |
| **Contribute code** | Read [CONTRIBUTING.md](CONTRIBUTING.md) first |

## Before opening an issue

1. **Search existing issues + Discussions** for your question. Most
   first-time "this doesn't work" issues have already been answered.
2. **Read the relevant module's `docs/EDGE_CASES.md`** — every module
   that handles non-trivial state has one. ~80% of the "is this a bug?"
   questions are answered there.
3. **Check the per-module CHANGELOG** for breaking changes if you're
   upgrading. SemVer pre-1.0 means minor versions can break.
4. **Confirm you're on a supported version.** See [SECURITY.md](SECURITY.md)
   for the version-support table.

## What to include in a bug report

The Issue template asks for these — provide them and the maintainer can
respond meaningfully on the first reply rather than asking three follow-ups:

- **Framework version + module version** (e.g. framework `0.2.1`,
  `instance-scheduler` `1.0.0`).
- **Terraform + AWS provider versions** (`terraform version`).
- **`terraform plan` output** (sensitive values redacted).
- **Lambda logs** if the issue is at runtime (CloudWatch log group for
  the affected Lambda, last ~50 lines around the error).
- **The minimal HCL** that reproduces the problem — ideally something
  derived from one of `examples/*` with one or two lines changed.
- **What you expected to happen.**

## Response times

Solidus FinOps is maintained on best-effort. Typical first-response
windows:

| Channel | Typical first response |
|---|---|
| Security report (private) | 48 hours — see [SECURITY.md](SECURITY.md) |
| Bug report | 3–7 days |
| Feature request | 7–14 days |
| Discussion / Q&A | Best-effort — sometimes faster from the community than the maintainer |

If something is on fire in production, prioritise unblocking yourself
first — the framework's safety defaults (off-by-default destructive
Lambdas, dry-run mode, `prevent_destroy` on data) are designed so you
can disable broken automation without touching the data plane:

```hcl
# Quick incident knobs
idle_cleanup_dry_run        = true   # stops cleanup mutations
instance_scheduler_enabled  = false  # stops scheduler ticks
budgets_performance_tracking_enabled = false   # stops the daily Lambda
```

Apply with `-target` if needed, then file an issue with details.

## Commercial support

There is currently no commercial support arrangement for Solidus FinOps.
Organisations needing paid support, SLA-backed response, or
implementation consulting can contact the maintainer directly at
**ivan.kovtun@dataart.com**. Whether such arrangements are offered is at
the maintainer's discretion.

## Helping other users

If you've solved a problem with the framework, the best thing you can do
is **answer someone else's question in Discussions** or **send a PR
that adds the gotcha to the relevant module's `docs/EDGE_CASES.md`**.
The framework gets better for everyone when the operational knowledge
moves out of individual heads and into the repo.

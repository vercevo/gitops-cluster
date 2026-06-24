# ADR-0001: Documentation architecture — rules vs. facts, single source of truth

**Status:** Accepted — 2026-06-24

## Context

A context-less agent (or human) given a task investigated the repo from scratch and
nearly acted on **stale, contradictory documentation**: `README.md` described the
original design (Kubernetes `Ingress`, `*.k8s.bergtobias.com` hostnames, cert-manager
per-service TLS, external-dns auto-DNS) while `RUNBOOK.md` described the cluster as it
actually runs (Gateway API `HTTPRoute`, `*.bergtobias.com`, TLS terminated at
Cloudflare, manually-created proxied CNAMEs). There was no `CLAUDE.md`, so nothing
oriented a fresh session before it started guessing.

The same overlap that produced the README↔RUNBOOK contradiction will reproduce in any
new doc that restates facts. The root cause is **duplicated facts**, not missing docs.

## Decision

Each doc has one role, and **no operational fact lives in more than one file.**

| File              | Owns                                              | Must NOT contain                         |
|-------------------|---------------------------------------------------|------------------------------------------|
| `CLAUDE.md`       | Invariant **rules**, the change **process**, an **index** of where facts live | Mutable facts (hostnames, IPs, endpoints, commands, patterns) |
| `RUNBOOK.md`      | The **single home of every operational fact**: GitOps flow, conventions, HTTPRoute/DNS/secrets/Postgres/OIDC patterns, component inventory, one-time bootstrap | n/a — this is the source of truth |
| `README.md`       | Human onboarding **narrative** + links            | Any operational fact (steps, URLs, secret names, manifest examples) |
| `docs/GLOSSARY.md`| Definitions of domain terms                       | Procedures or current-state facts        |
| `docs/adr/`       | Decisions + rationale (point-in-time)             | Live operational facts (cite RUNBOOK)    |

**Rule vs. fact:** an invariant principle that essentially never changes (e.g. "never
`kubectl apply` declarative state", "Gateway API only, never `Ingress`") is a *rule* and
belongs in `CLAUDE.md` as a guardrail. Anything that could change as the cluster evolves
(a hostname, a port, a secret name, the exact HTTPRoute block) is a *fact* and lives only
in `RUNBOOK.md`. Entrypoints point at facts; they do not copy them.

### Consequences for the existing docs
- `README.md` is **de-facted**: its networking sections, service-URL table, Ingress
  example, and step-by-step bootstrap are removed. It keeps a friendly description of
  what the repo is and links onward. (The earlier "banner + Reality-vs-README table"
  patch is deleted — once README holds no facts, there is no contradiction to reconcile.)
- The one-time **bootstrap steps move into `RUNBOOK.md`** (it already owned the
  Secrets/bootstrap concept). README links to them.
- `CLAUDE.md` is **stripped of facts** (cluster IP, hostnames, copy-these patterns,
  the Reality-vs-README table) and reduced to rules + process + index.

## Alternatives considered

- **Keep the banner, leave README's facts** — rejected: knowingly retains wrong facts
  behind a warning an agent can skim past; this is the hazard that started this.
- **RUNBOOK canonical, CLAUDE.md pure pointer (no rules)** — rejected: the entrypoint
  needs the non-negotiable guardrails visible at load time, and rules are near-zero-drift.
- **Accept duplication, keep in sync by discipline** — rejected: that discipline already
  failed once (README↔RUNBOOK).
- **Merge README into RUNBOOK** — viable, but loses README as a human front door for
  little gain; rejected in favour of de-facting.

## Related
- [ADR-0002](0002-mandatory-observable-preflight.md) — how we make the agent actually
  read the facts before editing.

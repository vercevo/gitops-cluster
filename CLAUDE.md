# CLAUDE.md — read this first, then follow the pre-flight

This repo is **GitOps state** for a k3s cluster: ArgoCD applies everything from git. You
change git, never the live cluster.

This file holds only **rules, process, and an index**. It deliberately contains **no
operational facts** (hostnames, IPs, ports, commands, manifest patterns) — those live in
exactly one place, `RUNBOOK.md`, so they can't drift. See
[docs/adr/0001](docs/adr/0001-docs-architecture.md) for why.

## Doc map — where things live

- **[RUNBOOK.md](RUNBOOK.md)** — the **single source of truth** for every operational
  fact: GitOps flow, conventions, the HTTPRoute / DNS / secrets / Postgres / OIDC
  patterns, the OutOfSync traps, the component inventory, and one-time bootstrap. Read it;
  do not re-derive it from the manifests.
- **[README.md](README.md)** — human onboarding narrative only. No operational facts.
- **[docs/GLOSSARY.md](docs/GLOSSARY.md)** — domain terms (sync wave, app-of-apps,
  HTTPRoute, CNPG, tunnel, …).
- **[docs/adr/](docs/adr/)** — decisions and their rationale.

## Iron rules (non-negotiable; rationale in RUNBOOK)

1. **Never `kubectl apply -f` declarative state.** All resources go through git + ArgoCD.
   (`kubectl annotate … refresh=hard` to trigger sync and `kubectl delete` for cleanup are
   fine.)
2. **Never use `Ingress`.** This cluster is **Gateway API only** — use `HTTPRoute`.

## Mandatory pre-flight

**Trigger:** any change to a file under `platform/`, `applications/`, or `bootstrap/`.

Before you write or alter a manifest, you MUST do this **in your response, first** — so
that skipping the context is visible, not silent (rationale:
[docs/adr/0002](docs/adr/0002-mandatory-observable-preflight.md)):

1. **Cite the applicable RUNBOOK rules** for this change — name the section (e.g. the
   HTTPRoute pattern, the DNS CNAME step, the OutOfSync defaulted-fields trap, the iron
   rules above).
2. **Name the nearest existing component you are copying** (a path under `platform/…`) and
   confirm your manifests match its shape.
3. **Then** edit. If a cited rule conflicts with your plan, stop and surface it.

A change whose response doesn't cite the rules it relied on is **incomplete**.

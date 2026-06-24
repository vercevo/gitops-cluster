# ADR-0002: Mandatory, observable pre-flight before any infra change

**Status:** Accepted — 2026-06-24

## Context

`CLAUDE.md` auto-loads each session; `RUNBOOK.md` (which holds the facts — see
[ADR-0001](0001-docs-architecture.md)) does not. A link from CLAUDE.md to RUNBOOK is
only a suggestion: nothing forces an agent to open RUNBOOK before it starts writing
manifests. A merely "mandatory"-worded checklist in markdown is structurally the same
compliance bet as a passive pointer — the only difference is tone, and a skipped read is
**silent**, so we can't even tell it happened.

We want the failure mode (acting without the context) to be **detectable**, without
standing up CI or settings hooks for a single-operator homelab.

## Decision

`CLAUDE.md` defines a pre-flight that produces a **visible artifact**, so compliance is
observable rather than trusted.

**Trigger:** any change to a file under `platform/`, `applications/`, or `bootstrap/`.
(One bright line — no judgment about whether a change is "big enough"; routine tweaks
are where the README-style drift bit, so they are not exempt.)

**Required emit-then-edit step.** Before writing/altering a manifest, the agent MUST, in
its response, first:
1. **Cite the applicable RUNBOOK rules** for this change (name the section — e.g. the
   HTTPRoute pattern, the DNS CNAME step, the OutOfSync defaulted-fields trap, the two
   iron rules).
2. **Name the nearest existing component** it is copying (a path under `platform/…`) and
   confirm its manifests match that shape.
3. **Then** edit. If a cited rule conflicts with the plan, stop and surface it.

A change whose response does not cite the rules it relied on is **incomplete** — the
missing citation is the visible signal that the pre-flight was skipped.

## Alternatives considered

- **Imperative phrasing only** — rejected: soft, and a skip is invisible.
- **settings.json hook** — strongest in-session guarantee, but deterministic enforcement
  is overkill here and adds machinery to maintain; kept in reserve if the soft approach
  proves insufficient.
- **CI lint gate** (reject manifests using `Ingress`, missing HTTPRoute defaulted fields,
  `.k8s.` hostnames) — real enforcement outside the agent's goodwill; deferred as a
  future hardening step, not needed before the observable checklist is in place.

## Consequences
- The contract lives in `CLAUDE.md` under "Mandatory pre-flight"; this ADR is its
  rationale.
- If checklist-skipping recurs despite the observable step, escalate to the CI gate
  (preferred) or the hook.

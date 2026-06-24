# gitops-cluster

GitOps-first single-node k3s cluster for `bergtobias.com`. **ArgoCD owns everything**
after a short one-time bootstrap: you change this git repo, and the cluster reconciles
itself to match. You don't `kubectl apply` cluster state by hand.

## Layout

```
bootstrap/      One-time manual setup scripts (k3s + ArgoCD install, secrets).
platform/       Infrastructure layer — one dir per component, each an ArgoCD Application.
applications/   Workload layer — drop an ArgoCD Application here to deploy an app.
docs/           Glossary and Architecture Decision Records (ADRs).
```

Two **app-of-apps** (`platform` and `applications`) auto-discover the `Application`
manifests in those directories, so adding a component is "add a file + push".

## Where to go next

This README is intentionally a front door only — it holds **no operational facts**, so
nothing here can go stale and contradict reality (see
[docs/adr/0001](docs/adr/0001-docs-architecture.md)).

- **Working on the cluster (human or agent)?** Start with **[CLAUDE.md](CLAUDE.md)** —
  the entry point and required pre-flight.
- **How does anything actually work? / How do I set it up?** **[RUNBOOK.md](RUNBOOK.md)**
  is the single source of truth: GitOps flow, conventions, the HTTPRoute / DNS / secrets /
  Postgres / OIDC patterns, the component inventory, and the one-time bootstrap steps.
- **Unfamiliar term?** **[docs/GLOSSARY.md](docs/GLOSSARY.md)**.
- **Why is it built this way?** **[docs/adr/](docs/adr/)**.

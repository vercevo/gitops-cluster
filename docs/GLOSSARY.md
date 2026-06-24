# Glossary

Domain terms for this repo. Definitions only — current-state facts (hostnames, IPs,
versions) live in [RUNBOOK.md](../RUNBOOK.md).

- **GitOps** — Operating model where the git repo is the source of truth for cluster
  state; a controller continuously reconciles the live cluster to match git.
- **ArgoCD** — The GitOps controller running in this cluster. It watches this repo and
  applies/reconciles everything. Humans/agents change git, not the live cluster.
- **App-of-apps** — An ArgoCD `Application` whose job is to discover and create other
  `Application`s. This repo seeds two: `platform` (recurses `platform/*/application.yaml`)
  and `applications` (recurses `applications/*/application.yaml`).
- **`Application` (ArgoCD)** — A CR declaring "deploy this source (Helm chart or path of
  manifests) into this namespace and keep it synced." One per component.
- **Sync wave** — `argocd.argoproj.io/sync-wave` annotation controlling ordering within a
  sync; lower numbers apply earlier. Used so dependencies (e.g. the Postgres operator)
  come up before dependents.
- **Helm-shape vs raw-manifest-shape** — The two forms an `Application` takes here: a Helm
  chart (`source.chart` + `repoURL`, values via a `$values` multi-source ref) or a
  directory of plain manifests (`source.path` + `directory.include/exclude`).
- **Gateway API** — The Kubernetes ingress successor used exclusively here. Traffic
  routing is expressed with `Gateway` + `HTTPRoute`, not the legacy `Ingress` resource.
- **`Gateway`** — The Gateway API object representing the ingress entry point (the cluster
  has one shared `Gateway` with a TLS listener). `HTTPRoute`s attach to it via `parentRefs`.
- **`HTTPRoute`** — Gateway API object mapping a hostname/path to a backend `Service`.
  The repo's canonical pattern (including server-defaulted fields that must be written
  explicitly to avoid OutOfSync) is in RUNBOOK.
- **Traefik** — The ingress controller implementing the Gateway API in this cluster.
- **Cloudflare Tunnel** — Outbound-only connection from the cluster to Cloudflare that
  publishes `*.bergtobias.com` without exposing the node's IP. TLS terminates at
  Cloudflare, not in-cluster.
- **external-dns** — Controller that can create DNS records from cluster objects. Note its
  limitation with the Gateway source is documented in RUNBOOK (why records are made
  manually).
- **Proxied CNAME** — A Cloudflare DNS record (orange-cloud) pointing a hostname at the
  tunnel. Public hostnames here are created this way manually; see RUNBOOK.
- **OutOfSync (defaulted-fields)** — ArgoCD showing a permanent diff because the API
  server/CRD injected default fields not present in git. Fixed by writing the defaults
  explicitly. Known cases (HTTPRoute, CNPG roles) are in RUNBOOK.
- **CloudNativePG / CNPG** — The PostgreSQL operator. App databases are declared as
  `Cluster` CRs; the repo's pattern is in RUNBOOK.
- **Authentik** — The self-hosted SSO / OpenID Connect provider for cluster apps.
- **OIDC provider / client** — In Authentik, a *provider* issues tokens for an
  *application*; a client app authenticates with a `client_id` + `client_secret` and a
  redirect URI. App secrets are injected from Kubernetes Secrets, never committed.
- **MinIO operator / tenant** — S3-compatible object storage: the *operator* manages
  *tenant* instances (object stores). Used for Backstage TechDocs.
- **Bootstrap secret** — A credential created out-of-band by a `bootstrap/*.sh` script via
  `kubectl create secret`. Secrets are deliberately not in git.
- **Pre-flight** — The mandatory, observable checklist an agent must satisfy before
  editing infra manifests. Defined in [CLAUDE.md](../CLAUDE.md), rationale in
  [ADR-0002](adr/0002-mandatory-observable-preflight.md).
- **Rule vs. fact** — The split governing where docs content goes: invariant rules live in
  CLAUDE.md; mutable facts live only in RUNBOOK. See
  [ADR-0001](adr/0001-docs-architecture.md).
- **k3s** — The lightweight single-node Kubernetes distribution this cluster runs on.

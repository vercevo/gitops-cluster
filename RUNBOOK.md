# Cluster Runbook

Hard-won operational knowledge for this k3s + ArgoCD cluster. Read this before
changing infra — several things here are non-obvious and cost real time to learn.

## Topology

- Single-node **k3s** at `192.168.10.10`.
- **ArgoCD** GitOps from `github.com/vercevo/gitops-cluster`.
- **Cloudflare Tunnel** `07a7a2df-49c5-41a5-8e59-6403b236a5d5` routes
  `*.bergtobias.com` → `https://traefik.traefik.svc.cluster.local:443`
  (`noTLSVerify: true`). TLS terminates at Cloudflare.
- **Traefik** is the ingress, using **Gateway API** — Gateway `main` in ns
  `traefik`, listener `websecure`.

## GitOps flow — how apps get deployed

`bootstrap/argocd-seed.yaml` seeds two app-of-apps:

- **platform** → recurses `platform/*/application.yaml`
- **applications** → recurses `applications/*/application.yaml`

So to add a platform component: create `platform/<name>/application.yaml` (an
ArgoCD `Application`). It's auto-discovered on the next `platform` app sync.
Use `argocd.argoproj.io/sync-wave` to order (lower = earlier).

Two shapes are used (see existing dirs):
- **Helm** (operators/charts): `application.yaml` with `source.chart` +
  `repoURL` (e.g. `cloudnativepg`, `cert-manager`, `minio-operator`).
- **Raw manifests**: `application.yaml` with `source.path: platform/<name>` +
  `directory.include: "*.yaml"` / `exclude: "application.yaml"`, and the actual
  manifests alongside (e.g. `backstage`, `minio-tenant`).

### Rules (learned the hard way)
- **NEVER `kubectl apply -f` cluster state.** All declarative resources go
  through git + ArgoCD. `kubectl annotate ... refresh=hard` (to trigger sync)
  and `kubectl delete` (cleanup) are fine.
- **NEVER use `Ingress`.** This cluster is Gateway API only. Use `HTTPRoute`.

## HTTPRoute pattern (copy this exactly)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <name>
  namespace: <ns>
  annotations:
    external-dns.alpha.kubernetes.io/managed: "true"
    external-dns.alpha.kubernetes.io/hostname: <host>.bergtobias.com
spec:
  parentRefs:
    - group: gateway.networking.k8s.io   # include these explicitly —
      kind: Gateway                       # the API server defaults them, and
      name: main                          # omitting them makes ArgoCD show a
      namespace: traefik                  # permanent OutOfSync diff.
      sectionName: websecure
  hostnames: [<host>.bergtobias.com]
  rules:
    - backendRefs:
        - group: ""                       # also include group/kind/weight to
          kind: Service                   # match the server-defaulted live obj
          name: <svc>
          port: <port>
          weight: 1
      matches:
        - path: { type: PathPrefix, value: / }
```

### ArgoCD OutOfSync from defaulted fields
CRDs/the API server inject defaults that ArgoCD then diffs against git. Fix by
writing the defaults explicitly in git. Seen with:
- **HTTPRoute** `parentRefs[].group/kind`, `backendRefs[].group/kind/weight`.
- **CNPG Cluster** `managed.roles[]`: add `ensure: present`, `inherit: true`,
  `connectionLimit: -1`.

## DNS — one wildcard, then just HTTPRoutes

A single **proxied wildcard** `*.bergtobias.com → <tunnel>.cfargotunnel.com`
(orange-cloud) resolves **every** cluster hostname. The tunnel forwards all of
`*.bergtobias.com` to Traefik, and Traefik host-routes by HTTPRoute hostname.

**So to expose a new service you add an HTTPRoute — and that's it. There is no
per-host DNS step.** (The old ritual was a manually-created proxied CNAME per
host, because external-dns can't create them; the wildcard makes that obsolete.)

The wildcard record (already created, `proxied=true`):

```bash
CF_TOKEN=$(kubectl get secret cloudflare-api-token -n external-dns -o jsonpath='{.data.token}' | base64 -d)
ZONE=0cbdabef317842e700c3238e4c996363
TUNNEL=07a7a2df-49c5-41a5-8e59-6403b236a5d5.cfargotunnel.com
curl -s -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  --data "{\"type\":\"CNAME\",\"name\":\"*.bergtobias.com\",\"content\":\"$TUNNEL\",\"proxied\":true}"
```

Verify a brand-new host routes (expect a Traefik **404**, served by `cloudflare`
— not a tunnel error): `curl -s -o /dev/null -w '%{http_code}' https://anything-new.bergtobias.com/`.

**Things to know:**
- **Existing per-host CNAMEs (grafana, argocd, …) are now redundant** — a specific
  record just takes precedence over the wildcard (same target). Harmless; leave or prune.
- **A new HTTPRoute is instantly public** via the wildcard — the per-host CNAME used
  to be an accidental "make it public" gate; that gate is gone. **Gate sensitive UIs
  behind Authentik / oauth2-proxy.**
- **Stay one DNS level deep.** Cloudflare terminates TLS at its edge with its own cert;
  free Universal SSL covers `bergtobias.com` + `*.bergtobias.com` (one level) but **not**
  a deeper wildcard like `*.k8s.bergtobias.com` (that needs Cloudflare Advanced Certificate
  Manager). The in-cluster `wildcard-k8s-bergtobias-com` cert does **not** help the public
  path — the tunnel runs `noTLSVerify`, so browsers see Cloudflare's edge cert, not Traefik's.
- The `external-dns.alpha.kubernetes.io/*` annotations on HTTPRoutes are now **cosmetic**
  (the wildcard does the resolving). external-dns's gateway source still mis-creates an
  A-record to the private node IP `192.168.10.10`, which Cloudflare rejects (`error 9003`);
  it is effectively **unused for ingress** and could be retired.

## Secrets — SOPS (migrating) + bootstrap scripts (legacy)

Two mechanisms, mid-migration from the second to the first:

**SOPS (the target).** Secrets live **encrypted in git** as `SopsSecret` CRs under
`platform/secrets/*.sops.yaml`; the `sops-secrets-operator` decrypts them into real
k8s Secrets. `.sops.yaml` holds the **public** age recipient (safe in git); the
**private** key is the single bootstrap secret — `.secrets/sops-age.key`
(git-ignored, installed via `bootstrap/sops-age-secret.sh`). **BACK UP that key —
lose it and every `*.sops.yaml` is unreadable.** Encrypt/edit with the `sops` CLI
(`sops -e -i file.sops.yaml` / `sops file.sops.yaml`). Migrated so far: `grafana-oidc`.

To add or migrate a secret:
```bash
# build a SopsSecret (stringData = the values), encrypt, commit:
sops --config .sops.yaml -e -i platform/secrets/<name>.sops.yaml
git add platform/secrets/<name>.sops.yaml && git commit && git push
# if a bootstrap-made secret already exists with that name, the operator refuses to
# adopt it ("Child secret is not owned") — delete it, then nudge a reconcile:
kubectl delete secret <name> -n <ns>
kubectl annotate sopssecret <name> -n <ns> reconcile.now="$(date +%s)" --overwrite
```

**Legacy bootstrap scripts.** The not-yet-migrated secrets are still created by
`bootstrap/*-secret.sh` via `kubectl create secret` (re-run a script to recreate its
secret; the scripts make the namespace first). Migrate them to SOPS as above when
convenient — higher-risk ones (`minio-tenant-config`, CNPG `*-pg-user`,
`cloudflare-api-token`) have live consumers that react to changes, so do those
deliberately.

## Bootstrap (one-time setup)

ArgoCD owns everything *after* these run-once steps. Secrets created here are never
committed (see above). Prerequisites: a Linux host, Cloudflare managing `bergtobias.com`,
a Cloudflare API token with `Zone:Read` + `DNS:Edit` on the zone, and this repo pushed to
GitHub.

**0 — Configure repo URL**
```bash
git clone <repo-url> && cd gitops-cluster
./bootstrap/configure.sh https://github.com/vercevo/gitops-cluster
git commit -am "Configure repo URL" && git push
```

**1 — Install k3s + ArgoCD** (on the node, as root). k3s installs with its bundled
Traefik disabled — ingress is managed via GitOps instead.
```bash
sudo REPO_URL=https://github.com/vercevo/gitops-cluster ./bootstrap/bootstrap.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get applications -n argocd -w          # watch the platform come up
# ArgoCD admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

**2 — Cloudflare secret** (creates the token secret in `cert-manager` and `external-dns`).
```bash
CF_API_TOKEN=<token> ./bootstrap/cloudflare-secret.sh
```

> **Vault was retired** — it was deployed and bootstrapped but had **zero
> consumers** (no vault-agent injection, no ESO/VSO), so it was pure overhead
> (~250Mi + manual unseal after every pod restart on a single node). Secrets are
> created by the per-component `bootstrap/*-secret.sh` scripts (see **Secrets**
> above). If you want git-managed secrets, the intended direction is **SOPS+age**
> (encrypted secrets committed to the repo), not Vault.

**Grafana rollout (one-time):**
1. In Authentik, create an **OAuth2/OpenID provider** + application `grafana`
   (app slug `grafana`). Redirect URI:
   `https://grafana.bergtobias.com/login/generic_oauth`. Optionally create a
   `Grafana Admins` group and add yourself (maps to Grafana Admin; others Viewer).
2. `GRAFANA_OIDC_CLIENT_ID=… GRAFANA_OIDC_CLIENT_SECRET=… ./bootstrap/grafana-secret.sh`
   (prints a break-glass local `admin` password; store it).
3. DNS: nothing to do — the `*.bergtobias.com` wildcard already resolves it (see **DNS** above).

**Loki rollout (one-time):**
1. `./bootstrap/loki-secret.sh` (reuses the MinIO root creds → secret `loki-s3`).
   The `loki` bucket is declared in `platform/minio-tenant/tenant.yaml` and
   auto-created by the MinIO operator — no manual bucket step.
2. No DNS/HTTPRoute: Loki is internal-only (queried by Grafana in-cluster).

**Tempo rollout (one-time):**
1. `./bootstrap/tempo-secret.sh` (reuses MinIO root creds → secret `tempo-s3`).
2. The `tempo` bucket: declared in `tenant.yaml`, but the operator does **not**
   auto-create buckets added to an existing tenant — create it once with `mc`
   (see the loki+tempo gotcha below). No DNS/HTTPRoute (internal-only).

**MinIO Console OIDC (one-time):**
1. In Authentik, create an **OAuth2/OpenID provider** + application `minio`
   (app slug `minio`). Redirect URI: `https://minio.bergtobias.com/oauth_callback`.
2. `MINIO_OIDC_CLIENT_ID=… MINIO_OIDC_CLIENT_SECRET=… ./bootstrap/minio-oidc-secret.sh`
   (injects OIDC into `config.env` and restarts the tenant pod).
3. DNS: nothing to do — the `*.bergtobias.com` wildcard resolves `minio.bergtobias.com`.

Per-component secret scripts (`github-app-secret.sh`, `minio-secret.sh`,
`grafana-secret.sh`, `loki-secret.sh`, `tempo-secret.sh`, `minio-oidc-secret.sh`, …)
are run as needed — see "Secrets" above and the component entries below.

**Dagster rollout (one-time):**
1. Code + Evidence images publish to GHCR from `vercevo/elt-tutorial`
   (`.github/workflows/build-images.yml`). Confirm both packages are green.
2. In Authentik, create an **OAuth2/OpenID provider** + application `dagster`
   (app slug `dagster`). Redirect URI: `https://dagster.bergtobias.com/oauth2/callback`.
3. `DAGSTER_OIDC_CLIENT_ID=… DAGSTER_OIDC_CLIENT_SECRET=… ./bootstrap/dagster-secret.sh`
4. DNS: nothing to do — the `*.bergtobias.com` wildcard resolves both
   `dagster.bergtobias.com` and `jaffle.bergtobias.com` (see **DNS** above).

## Components

- **cloudnativepg** — Postgres operator (`cnpg-system`). App DBs are `Cluster`
  CRs (e.g. `backstage/postgres.yaml`). Each `Cluster` opts into metrics with
  `spec.monitoring.enablePodMonitor: true` (scraped by kube-prometheus-stack).
- **kube-prometheus-stack** — observability stack (ns `monitoring`): Prometheus
  Operator + Prometheus + Grafana + node-exporter + kube-state-metrics. Helm
  multi-source app (`prometheus-community/kube-prometheus-stack` +
  `platform/kube-prometheus-stack/values.yaml`), **sync-wave 1** so the
  ServiceMonitor/PodMonitor/PrometheusRule CRDs exist before app-level monitors.
  **Grafana** at `grafana.bergtobias.com` via **native Authentik OIDC**
  (`generic_oauth`, not oauth2-proxy); the `Grafana Admins` Authentik group maps
  to admin, else Viewer. Secret via `bootstrap/grafana-secret.sh`. **Alerting is
  on:** Alertmanager runs (bundled `defaultRules` for k8s/node), and a set of
  **Grafana-managed rules routed to Discord** is provisioned declaratively from
  `platform/kube-prometheus-stack/alerting-values.yaml` (merged via a second
  `valueFiles` entry) — node mem/CPU/disk, pod OOMKilled, crash-looping, PVC full,
  node-not-Ready. Logs (Loki) and traces (Tempo, now removed) are separate. **Gotchas:**
  - **Grafana alert rules: put the threshold in expression C, NOT in the query.**
    A rule whose query is `expr > 90` returns *no rows* while healthy; Grafana reads
    that empty result as **NoData** and (with `noDataState` set to alert) pages you
    with `alertname=DatasourceNoData` — i.e. it fires precisely *because the box is
    fine*. The fix: query A returns the raw value, expression C is a `threshold`
    (`gt 90`), and `noDataState: OK`. The original 3 UI-made rules had this bug;
    `alerting-values.yaml` reuses their UIDs so provisioning overwrites them.
    Provisioned rules are read-only in the UI (provenance=file) — edit git, not the UI.
  - **Authentik OIDC endpoints are GLOBAL, not per-slug.** Grafana's
    `auth_url`/`token_url`/`api_url` must be `/application/o/{authorize,token,userinfo}/`
    (no slug). Only the **issuer** and **jwks_uri** are per-app-slug
    (`/application/o/grafana/`). Using a per-slug authorize URL 404s and surfaces as
    "application not found" at login. (Applies to any native-OIDC client; oauth2-proxy
    auto-discovers from the issuer and avoids this.)
  - **`*SelectorNilUsesHelmValues: false`** (service/pod/rule/probe/scrapeConfig)
    in values — otherwise Prometheus only scrapes monitors carrying the chart's
    release label and silently ignores app-namespace ones.
  - **k3s control-plane targets disabled** (`kubeScheduler`/`kubeControllerManager`/
    `kubeEtcd`/`kubeProxy` `enabled: false`) — k3s bundles them into one binary, so
    they're not separately scrapable and would show as permanently "down".
  - **Prometheus TSDB is a local-path PVC** (7d / 6GiB), not S3. S3/MinIO only
    enters the picture with Loki in the deferred logs phase.
  - **Trimmed for the 7.6Gi node**: 60s scrape, WAL compression, Prometheus mem
    limit 512Mi, Grafana 256Mi. The untrimmed default stack OOM-pressured the node
    (which is why **dagster compute is disabled** below — they don't both fit). Keep
    this lean until RAM grows.
  - **Do NOT disable the Grafana sidecars.** In kube-prometheus-stack the
    `sidecar.datasources`/`sidecar.dashboards` sidecars are what provision the
    Prometheus datasource and load the bundled dashboards. An earlier over-trim set
    them `false`, which left Grafana with **no datasource at all** (manual
    `additionalDataSources` did not render a provisioning file). They are on.
- **loki + promtail** — **⚠ REMOVED to free RAM** on the 7.6Gi node (was ~237Mi:
  loki 172 + promtail 65). The node was at 79% and swapping; dropping the logging tail
  reclaimed the most RAM with the least loss (single-node homelab, logs were 72h-retention
  only). The `platform/loki` and `platform/promtail` Application dirs were deleted, so the
  `platform` app-of-apps pruned both. This also freed Loki's **only** live MinIO consumer,
  so the **minio Tenant was dropped too** (see **minio** below). This leaves Grafana with
  **metrics only** (Prometheus) — the **L** and the storage tail of LGTM are gone.
  **Revive:** restore both dirs from git history
  (`git checkout <pre-removal-sha> -- platform/loki platform/promtail`), bring the minio
  Tenant back first (Loki needs the `loki` bucket on S3), then re-run
  `bootstrap/loki-secret.sh`. Loki was `grafana/loki` single-binary → the MinIO `loki`
  bucket (`minio.minio.svc.cluster.local:80`, path-style, plain HTTP), with the chart's
  memcached caches / scalable-mode / bundled minio / gateway / canary all disabled, and
  S3 creds from the `loki-s3` secret via `singleBinary.extraEnvFrom`.
- **tempo + opentelemetry-collector** — **⚠ REMOVED to free RAM** on the 7.6Gi node
  (the tracing tail was ~180Mi of pure overhead: **traces stayed empty because nothing
  is auto-instrumented yet**). The `platform/tempo` and `platform/opentelemetry-collector`
  Application dirs were deleted, so the `platform` app-of-apps pruned both. This drops the
  **T** from the Grafana **LGTM** stack — metrics (Prometheus) + logs (Loki) remain.
  **Revive** when apps actually emit OTLP spans: restore both dirs from git history
  (`git checkout <pre-removal-sha> -- platform/tempo platform/opentelemetry-collector`),
  re-run `bootstrap/tempo-secret.sh`, and ensure the `tempo` MinIO bucket exists (the
  operator doesn't auto-create buckets on an existing tenant — `mc mb` it once). The OTel
  chart needs `mode` + `image.repository` set explicitly (contrib image,
  `command.name: otelcol-contrib`). The `tempo` MinIO bucket + its 5Gi PVC were left
  in place.
- **dagster** — Dagster orchestrator for the `elt-tutorial` ELT (ns `dagster`),
  replacing Airflow. **⚠ COMPUTE CURRENTLY DISABLED** to free RAM for the
  observability stack — this 7.6Gi node can't run both (the Evidence build was
  OOM-crash-looping). In git: `dagsterWebserver.replicaCount: 0`,
  `dagsterDaemon.enabled: false`, `dagster-user-deployments.{enabled,enableSubchart}: false`
  (both flags needed — disabling only `enabled` fails the webserver workspace template),
  `evidence`/`oauth2-proxy` `replicas: 0`. **The CNPG DBs (jaffle-pg/dagster-pg) have
  been DROPPED** (disposable ELT/demo data) to relieve the leader-election-flapping CNPG
  operator (fewer clusters). Reviving dagster therefore means restoring the replica
  counts/flags **and** re-adding `postgres.yaml` (the 2 Clusters) + re-materializing data.
  Official Helm chart (`dagster/dagster`, multi-source app +
  `applications/dagster/values.yaml`). `K8sRunLauncher` (each run is a Job pod);
  metadata DB is CNPG `dagster-pg`, the analytics **warehouse** is CNPG `jaffle-pg`
  (db `jaffle`, schema `main`). Code-location image
  `ghcr.io/vercevo/elt-tutorial-dagster` (`-m etl_tutorial.definitions`), built by the
  app repo CI. **Evidence** dashboard (`ghcr.io/vercevo/elt-tutorial-evidence`) at
  `jaffle.bergtobias.com` reads the warehouse. The UI at `dagster.bergtobias.com` has
  **no native auth** — it sits behind **oauth2-proxy** → Authentik OIDC (the HTTPRoute
  targets `oauth2-proxy`, not the webserver). Secrets via `bootstrap/dagster-secret.sh`
  (incl. a `ghcr-pull` copied from the backstage ns, and the metadata secret's extra
  `postgresql-password` key the chart requires). **Gotchas:**
  - **Warehouse is Postgres, not DuckDB.** The tutorial ships DuckDB (single-file,
    single-writer) which can't be shared across run pods; assets/dbt/Evidence were
    repointed at CNPG `jaffle-pg`.
  - **`includeConfigInLaunchedRuns: true`** so launched run Jobs inherit the code
    pod's image + PG* env — otherwise runs can't reach the warehouse.
  - **Evidence builds at pod start**, but the warehouse is empty until the first
    materialization: `kubectl rollout restart deploy/evidence -n dagster` after a run.
- **backstage** — developer portal at `backstage.bergtobias.com` (ns `backstage`, raw
  manifests). **⚠ CURRENTLY DISABLED** to free RAM on the 7.6Gi node: its
  ArgoCD **auto-sync is off** (`automated` block commented in `application.yaml`),
  `deployment.yaml` `replicas: 0`, and **the CNPG DB (`backstage-pg`) was DROPPED**
  (`postgres.yaml` removed — catalog is re-ingestible from git). Because auto-sync is off,
  the running Deployment + Cluster were torn down with `kubectl delete` (git won't recreate
  them). **Revive:** restore `replicas: 1`, re-add `postgres.yaml` from git history, then
  `argocd app sync backstage` (or re-enable the `automated` block).
- **authentik** — SSO at `authentik.bergtobias.com`. Admin ops via
  `kubectl exec -n authentik deploy/authentik-server -- ak shell`. **Blueprints
  (config-as-code):** custom blueprints live in
  `platform/authentik/blueprints-configmap.yaml` (ConfigMap; each `.yaml` key is a
  blueprint), mounted into the pods via `blueprints.configMaps` and auto-applied by
  the **worker** (mount path `/blueprints/mounted/cm-authentik-blueprints/`).
  Discovery runs periodically; force it with
  `ak shell -c 'from authentik.blueprints.v1.tasks import blueprints_discovery; blueprints_discovery.delay()'`
  on the **worker**, then check `BlueprintInstance` status. **All OIDC providers +
  applications are now declarative** (argocd, backstage, dagster, grafana, minio,
  johanjoel, umami) in the `oidc-apps.yaml` blueprint, plus the `Grafana Admins` group. Each
  provider's **client_secret is set via `!Env OIDC_<APP>_CLIENT_SECRET`**, injected
  into the authentik pods (values.yaml `global.env`) from the **`authentik-oidc-secrets`**
  Secret (SOPS: `platform/secrets/authentik-oidc-secrets.sops.yaml`) — so secrets never
  land in the in-git ConfigMap. The blueprint is **generated** from the live providers by
  `scripts/gen-authentik-blueprints.py` (regenerate + re-encrypt the secret if you add an
  app). Airflow (retired) is intentionally excluded. **To add a new OIDC app:** add its
  client_secret to the SopsSecret + a `global.env` entry, add an entry to the generator/
  blueprint, push — match `client_id`/flows exactly or you'll break live login.
- **minio** — S3 object storage. **Operator KEPT, Tenant DROPPED.** The
  `minio-operator` (<27Mi, two tiny controllers) stays — it's cheap and finalizes the
  tenant deletion cleanly. The **Tenant `techdocs` was removed (~300Mi)**: its only live
  consumer was Loki (now removed), and Backstage/`techdocs` is disabled, Tempo gone — so
  it had nothing left to serve. `platform/minio-tenant` was deleted; the `platform`
  app-of-apps pruned the Tenant + its console/S3 HTTPRoutes + PVCs. **Revive:** restore
  `platform/minio-tenant` from git history, re-run `bootstrap/minio-secret.sh`, then (for
  Loki/Tempo) `bootstrap/loki-secret.sh` / `tempo-secret.sh` and `mc mb` the buckets — the
  operator does **not** auto-create buckets on an existing tenant. Tenant was SNSD; buckets
  `techdocs`/`loki`/`tempo`; S3 external at `s3.bergtobias.com`, in-cluster
  `http://minio.minio.svc.cluster.local:80`; Console at `minio.bergtobias.com` via Authentik
  OIDC (role-policy `consoleAdmin`). **Gotcha that survives revival:** OIDC env must go into
  the `config.env` secret (operator v7.1.1 ignores Tenant `spec.env`); `minio-oidc-secret.sh`
  patches it, and re-running `minio-secret.sh` drops the OIDC lines (re-run the oidc script).
  The leftover `minio-tenant-config` / `loki-s3` / `tempo-s3` secrets and the Authentik
  `minio` OIDC app are now unused but harmless (left in place, like Tempo's bucket was).

- **actual** — Actual Budget (personal finance) at `actual.bergtobias.com` (ns
  `actual`, raw manifests, `bootstrap/`-free). Official image `actualbudget/actual-server`,
  port `5006`, SQLite data on a `local-path` PVC (`actual-data`, 2Gi) — **not** CNPG,
  Actual doesn't use Postgres. **Native OIDC** (unlike umami/johanjoel/dagster) — no
  oauth2-proxy; the HTTPRoute targets the `actual` Service directly.
  `ACTUAL_OPENID_DISCOVERY_URL` is the **per-app-slug** Authentik endpoint
  (`https://authentik.bergtobias.com/application/o/actual/`) — Actual does its own
  `.well-known` discovery from that, so (like oauth2-proxy) it **avoids** the
  global-authorize-URL gotcha that native clients like Grafana hit.
  `ACTUAL_OPENID_CLIENT_ID`/`SERVER_HOSTNAME` are plain env (not secret — the
  client_id is already committed in cleartext in the Authentik blueprint below, same
  as every other app); `ACTUAL_OPENID_CLIENT_SECRET` comes from `actual-secrets`
  (SOPS). **Gotcha: first OIDC login becomes the Actual server owner/admin** — log in
  as yourself first. **Secrets are pure SOPS, no bootstrap script**: the Authentik-side
  client secret lives in its own `actual-oidc-authentik-secret` SopsSecret
  (`platform/secrets/actual-oidc-authentik.sops.yaml`), **not** appended into the
  shared `authentik-oidc-secrets` file — that file already holds 7 apps' secrets
  encrypted, and appending to it requires decrypting the whole document (the private
  age key), whereas a standalone secret only needs the **public** age key (safe in
  git) to create. Same client_secret value duplicated into `actual-secrets` (ns
  `actual`) for the app's own side of the handshake.

## Quick checks

```bash
kubectl get applications -n argocd
kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl get httproute -A
kubectl get tenant -n minio
```

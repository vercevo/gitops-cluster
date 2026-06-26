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

## DNS — the painful part

`external-dns` runs (source `gateway-httproute`) but its current version has
"new behavior": when the HTTPRoute/Gateway provides a target it **ignores**
`--default-targets` (the tunnel) and tries to create an **A record to the
private node IP `192.168.10.10`** — which **Cloudflare rejects for proxied
records** (`error 9003`). The `external-dns.alpha.kubernetes.io/target`
annotation does NOT override this for the gateway source.

**Therefore: every public hostname is a manually-created proxied CNAME → tunnel,
via the Cloudflare API.** external-dns can't own them (its create fails), so it
leaves them alone. To add one:

```bash
CF_TOKEN=$(kubectl get secret cloudflare-api-token -n external-dns -o jsonpath='{.data.token}' | base64 -d)
ZONE=0cbdabef317842e700c3238e4c996363
TUNNEL=07a7a2df-49c5-41a5-8e59-6403b236a5d5.cfargotunnel.com
curl -s -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  --data "{\"type\":\"CNAME\",\"name\":\"<host>.bergtobias.com\",\"content\":\"$TUNNEL\",\"proxied\":true}"
```

Verify: `dig +short <host>.bergtobias.com` (Cloudflare IPs) and
`curl -s -o /dev/null -w '%{http_code}' https://<host>.bergtobias.com/`.

The wildcard tunnel already routes any `*.bergtobias.com` to Traefik, so you
only need the CNAME + an HTTPRoute.

## Secrets — bootstrap, not GitOps

Credentials are **not** in git. They're created by `bootstrap/*.sh` scripts
(e.g. `github-app-secret.sh`, `cloudflare-secret.sh`, `minio-secret.sh`) using
`kubectl create secret`. Re-run a script to (re)create its secret. Namespaces
must exist before the secret; the scripts handle that.

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

**3 — Initialize Vault** (wait until `vault-0` is Running). Writes unseal key + root token
to `.secrets/vault-init.json` (git-ignored) — **back this up**.
```bash
./bootstrap/vault-init.sh
# Unseal after a pod restart:
KEY=$(python3 -c "import json;print(json.load(open('.secrets/vault-init.json'))['unseal_keys_b64'][0])")
kubectl exec -n vault vault-0 -- vault operator unseal "$KEY"
```

**4 — Configure Vault** (Kubernetes auth + KV-v2).
```bash
TOKEN=$(python3 -c "import json;print(json.load(open('.secrets/vault-init.json'))['root_token'])")
VAULT_TOKEN="$TOKEN" ./bootstrap/vault-configure.sh
```

**Grafana rollout (one-time):**
1. In Authentik, create an **OAuth2/OpenID provider** + application `grafana`
   (app slug `grafana`). Redirect URI:
   `https://grafana.bergtobias.com/login/generic_oauth`. Optionally create a
   `Grafana Admins` group and add yourself (maps to Grafana Admin; others Viewer).
2. `GRAFANA_OIDC_CLIENT_ID=… GRAFANA_OIDC_CLIENT_SECRET=… ./bootstrap/grafana-secret.sh`
   (prints a break-glass local `admin` password; store it).
3. Add a proxied CNAME `grafana.bergtobias.com` → tunnel (see **DNS** above).

**Loki rollout (one-time):**
1. `./bootstrap/loki-secret.sh` (reuses the MinIO root creds → secret `loki-s3`).
   The `loki` bucket is declared in `platform/minio-tenant/tenant.yaml` and
   auto-created by the MinIO operator — no manual bucket step.
2. No DNS/HTTPRoute: Loki is internal-only (queried by Grafana in-cluster).

Per-component secret scripts (`github-app-secret.sh`, `minio-secret.sh`,
`grafana-secret.sh`, `loki-secret.sh`, …) are run as needed — see "Secrets" above
and the component entries below.

**Dagster rollout (one-time):**
1. Code + Evidence images publish to GHCR from `vercevo/elt-tutorial`
   (`.github/workflows/build-images.yml`). Confirm both packages are green.
2. In Authentik, create an **OAuth2/OpenID provider** + application `dagster`
   (app slug `dagster`). Redirect URI: `https://dagster.bergtobias.com/oauth2/callback`.
3. `DAGSTER_OIDC_CLIENT_ID=… DAGSTER_OIDC_CLIENT_SECRET=… ./bootstrap/dagster-secret.sh`
4. Add proxied CNAMEs `dagster.bergtobias.com` and `jaffle.bergtobias.com` → tunnel
   (see **DNS** above).

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
  to admin, else Viewer. Secret via `bootstrap/grafana-secret.sh`. **Scope is
  metrics + dashboards only** — Alertmanager is disabled and logs (Loki/Alloy on
  MinIO S3) and traces (Tempo) are deferred. **Gotchas:**
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
- **loki + promtail** — log aggregation (ns `loki`), the Phase 2 of observability.
  **Loki** (`grafana/loki`, single-binary/monolithic mode) stores chunks + index in
  the MinIO **`loki` bucket** (S3, `minio.minio.svc.cluster.local:80`, path-style,
  plain HTTP); 72h retention. **Promtail** (`grafana/promtail`, DaemonSet) tails all
  pod logs → Loki. Grafana queries it via a **Loki datasource** shipped as a labelled
  configmap (`grafana_datasource: "1"`) into the `monitoring` ns so the Grafana sidecar
  auto-provisions it. S3 creds via `bootstrap/loki-secret.sh` (secret `loki-s3`, reuses
  the MinIO root creds; read from env, not git). **Gotchas:**
  - **Disable the chart's memcached caches.** `chunksCache`/`resultsCache` default to
    multi-GiB memory requests and would never schedule on this node — both `enabled: false`,
    along with the scalable-mode `read`/`write`/`backend`, the bundled `minio`, `gateway`,
    and `lokiCanary`. Single-binary + S3 only.
  - **Loki S3 creds come from the `loki-s3` secret via env** (`AWS_ACCESS_KEY_ID`/
    `AWS_SECRET_ACCESS_KEY`, `singleBinary.extraEnvFrom`) — the s3 config block carries
    no keys, so nothing secret lands in git.
- **dagster** — Dagster orchestrator for the `elt-tutorial` ELT (ns `dagster`),
  replacing Airflow. **⚠ COMPUTE CURRENTLY DISABLED** to free RAM for the
  observability stack — this 7.6Gi node can't run both (the Evidence build was
  OOM-crash-looping). In git: `dagsterWebserver.replicaCount: 0`,
  `dagsterDaemon.enabled: false`, `dagster-user-deployments.{enabled,enableSubchart}: false`
  (both flags needed — disabling only `enabled` fails the webserver workspace template),
  `evidence`/`oauth2-proxy` `replicas: 0`. The **CNPG Postgres data (jaffle-pg/dagster-pg)
  is left running and untouched**. Re-enable by restoring those replica counts / flags
  once the node has more RAM. Official Helm chart (`dagster/dagster`, multi-source app +
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
- **harbor** — OCI registry at `harbor.bergtobias.com`. Internal pushes bypass
  Cloudflare's 100MB limit via a CoreDNS rewrite (`platform/coredns`) that
  points `harbor.bergtobias.com` at `traefik.traefik.svc.cluster.local`.
- **authentik** — SSO at `authentik.bergtobias.com`. Admin ops via
  `kubectl exec -n authentik deploy/authentik-server -- ak shell`.
- **minio** — S3 object storage for Backstage TechDocs. Operator
  (`minio-operator`) + Tenant `techdocs` (`minio` ns, SNSD, bucket `techdocs`).
  S3 API external at `s3.bergtobias.com`; in-cluster at
  `http://minio.minio.svc.cluster.local` (port 80). Root creds in
  `minio-tenant-config` (ns minio); Backstage read creds in `minio-techdocs`
  (ns backstage). See `bootstrap/minio-secret.sh`.

## Quick checks

```bash
kubectl get applications -n argocd
kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl get httproute -A
kubectl get tenant -n minio
```

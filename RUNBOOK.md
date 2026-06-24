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

Per-component secret scripts (`github-app-secret.sh`, `minio-secret.sh`,
`airflow-secret.sh`, …) are run as needed — see "Secrets" above and the component
entries below.

**Airflow rollout (one-time):**
1. Create repo `vercevo/airflow-dags` with a `dags/` folder (at least one DAG).
2. In Authentik, create an **OAuth2/OpenID provider** + application `airflow`.
   Redirect URI: `https://airflow.bergtobias.com/auth/oauth-authorized/authentik`
   (note the `/auth` prefix — Airflow 3). Create a group `airflow-admins` and add
   yourself; ensure the `groups` claim is in the userinfo scope.
3. `AIRFLOW_OIDC_CLIENT_ID=… AIRFLOW_OIDC_CLIENT_SECRET=… ./bootstrap/airflow-secret.sh`
4. Add the proxied CNAME `airflow.bergtobias.com` → tunnel (see **DNS** above).

## Components

- **airflow** — Apache Airflow 3 DAG orchestrator at `airflow.bergtobias.com`
  (ns `airflow`). Official Helm chart (`apache-airflow/airflow`, multi-source app
  + `platform/airflow/values.yaml`). `KubernetesExecutor` (tasks run as pods, no
  Celery/Redis); metadata DB is a CNPG `Cluster` (`airflow-pg`). Login is
  **Authentik OIDC** via the FAB auth manager (`webserver.webserverConfig`); the
  UI is served by Service `airflow-api-server:8080` (Airflow 3 has no `webserver`
  service). Authentik groups map to roles: `airflow-admins` → Admin,
  `airflow-users` → User. DAGs are git-synced from `vercevo/airflow-dags`
  (`dags/` subpath). Secrets via `bootstrap/airflow-secret.sh`. **Gotcha:** the
  Airflow 3 OAuth callback is `/auth/oauth-authorized/authentik` (the `/auth`
  prefix is new in 3.x — `/oauth-authorized/authentik` is the 2.x path).
- **cloudnativepg** — Postgres operator (`cnpg-system`). App DBs are `Cluster`
  CRs (e.g. `backstage/postgres.yaml`).
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

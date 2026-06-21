# gitops-cluster

GitOps-first k3s cluster for `bergtobias.com`. ArgoCD owns everything after a short bootstrap.

## Architecture

```
bootstrap/                   ← Minimal manual steps (run once per cluster)
  configure.sh               ← Stamps repo URL into seed manifests
  bootstrap.sh               ← Installs k3s + ArgoCD, seeds the control loop
  cloudflare-secret.sh       ← Creates CF API token secret (never committed)
  vault-init.sh              ← One-time Vault unseal key generation
  vault-configure.sh         ← One-time Vault Kubernetes auth setup
  argocd-seed.yaml           ← Seed manifest (applied by bootstrap.sh)

platform/                    ← Infrastructure layer — managed by ArgoCD
  argocd/                    ← ArgoCD manages itself (Helm, wave 0)
  traefik/                   ← API gateway + ingress controller (wave 1)
  cert-manager/              ← TLS via Let's Encrypt Cloudflare DNS-01 (wave 1)
  cert-manager-issuers/      ← ClusterIssuers + wildcard *.k8s.bergtobias.com cert (wave 2)
  external-dns/              ← Auto-creates Cloudflare DNS records from Ingresses (wave 1)
  vault/                     ← Secrets management (wave 1)

applications/                ← Workload layer — add your apps here
  <myapp>/application.yaml   ← Drop an ArgoCD Application here to deploy an app
```

**Sync waves** control platform startup order: ArgoCD (0) → infra (1) → issuers + certs (2).

**Platform vs Applications** are separate App-of-Apps so you can lock down platform changes
independently from app deployments.

## Service URLs

All cluster services live under `k8s.bergtobias.com`:

| Service      | URL                                |
|--------------|------------------------------------|
| ArgoCD       | https://argocd.k8s.bergtobias.com  |
| Vault        | https://vault.k8s.bergtobias.com   |
| Your apps    | https://\<name\>.k8s.bergtobias.com |

TLS is a wildcard cert (`*.k8s.bergtobias.com`) from Let's Encrypt via Cloudflare DNS-01.
external-dns automatically creates DNS records in Cloudflare when you add an Ingress.

## Bootstrap (4 steps, ~15 minutes)

### Prerequisites
- Linux server with public IP (or Cloudflare Tunnel for private)
- Cloudflare managing `bergtobias.com`
- A Cloudflare API token with `Zone / DNS / Edit` + `Zone / Zone / Read` on `bergtobias.com`
- This repo pushed to GitHub/GitLab

---

### Step 0 — Configure repo URL

```bash
git clone <your-repo-url>
cd gitops-cluster
./bootstrap/configure.sh https://github.com/YOUR_USER/gitops-cluster
git commit -am "Configure repo URL" && git push
```

---

### Step 1 — Install k3s + ArgoCD (run on server as root)

```bash
sudo REPO_URL=https://github.com/YOUR_USER/gitops-cluster ./bootstrap/bootstrap.sh
```

Installs k3s (Traefik disabled — we manage it via GitOps), installs ArgoCD, seeds the
platform and applications App-of-Apps. ArgoCD takes over from here.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get applications -n argocd -w   # watch platform come up
```

ArgoCD admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

---

### Step 2 — Cloudflare secret (one-time)

Create a Cloudflare API token at https://dash.cloudflare.com/profile/api-tokens with:
- `Zone / Zone / Read` — all zones (or just bergtobias.com)
- `Zone / DNS / Edit` — bergtobias.com

```bash
CF_API_TOKEN=<your-token> ./bootstrap/cloudflare-secret.sh
```

This creates the secret in `cert-manager` (for TLS) and `external-dns` (for DNS records).
The token is never stored in git.

Once this is done, cert-manager-issuers will sync, issue the wildcard cert, and external-dns
will start creating `k8s.bergtobias.com` records for every annotated Ingress.

---

### Step 3 — Initialize Vault (one-time)

Wait until `kubectl get pods -n vault` shows `vault-0` Running:

```bash
./bootstrap/vault-init.sh
```

Saves unseal key + root token to `.secrets/vault-init.json` (git-ignored).
**Back this file up somewhere secure** (1Password, etc.).

Re-seal happens on pod restart. To unseal:
```bash
KEY=$(python3 -c "import sys,json; print(json.load(open('.secrets/vault-init.json'))['unseal_keys_b64'][0])")
kubectl exec -n vault vault-0 -- vault operator unseal "${KEY}"
```

---

### Step 4 — Configure Vault (one-time)

```bash
TOKEN=$(python3 -c "import sys,json; print(json.load(open('.secrets/vault-init.json'))['root_token'])")
VAULT_TOKEN="${TOKEN}" ./bootstrap/vault-configure.sh
```

Sets up Kubernetes auth + KV-v2 so workloads can read secrets via Vault agent/sidecar.

---

## Adding an Application

Create `applications/<myapp>/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/MY_ORG/myapp
    targetRevision: HEAD
    path: helm
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

To get automatic DNS + TLS for `myapp.k8s.bergtobias.com`, add to your Ingress:
```yaml
annotations:
  external-dns.alpha.kubernetes.io/managed: "true"
  cert-manager.io/cluster-issuer: letsencrypt-prod
```

Commit and push — ArgoCD syncs automatically. No kubectl needed.

---

## Upgrading Platform Components

Change `targetRevision` in `platform/*/application.yaml` and push. ArgoCD handles the upgrade.

## Production Checklist

- [ ] Replace Vault file storage with Raft + auto-unseal (Cloudflare KV or AWS KMS)
- [ ] Set ArgoCD and Vault replicas > 1 for HA
- [ ] Lock down Traefik dashboard behind auth middleware
- [ ] Rotate Vault root token after initial setup (keep unseal key only)
- [ ] Add Prometheus + Grafana to `applications/` for observability
- [ ] Consider Cloudflare Tunnel (`cloudflared`) if server has no public IP

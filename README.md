# gitops-cluster

GitOps-first k3s cluster. ArgoCD owns everything after a 3-step bootstrap.

## Architecture

```
bootstrap/                   ← Minimal manual steps (run once per cluster)
  configure.sh               ← Stamps your repo URL + domain into all manifests
  bootstrap.sh               ← Installs k3s + ArgoCD, seeds the control loop
  vault-init.sh              ← One-time Vault unseal key generation
  vault-configure.sh         ← One-time Vault Kubernetes auth setup
  argocd-seed.yaml           ← Seed manifest (applied by bootstrap.sh)

platform/                    ← Infrastructure layer — managed by ArgoCD
  argocd/                    ← ArgoCD manages itself (Helm, wave 0)
  traefik/                   ← API gateway + ingress controller (wave 1)
  cert-manager/              ← TLS certificate management (wave 1)
  cert-manager-issuers/      ← ClusterIssuers: selfsigned, LE staging, LE prod (wave 2)
  vault/                     ← Secrets management (wave 1)

applications/                ← Workload layer — add your apps here
  <myapp>/application.yaml   ← Drop an ArgoCD Application here to deploy an app
```

**Separation of concerns:**
- `platform/` is infrastructure. Changes here affect the whole cluster.
- `applications/` is workloads. Each team owns their own subdirectory.
- ArgoCD's App-of-Apps pattern means adding a folder = deploying an app. No manual kubectl.

## Bootstrap (3 steps, ~10 minutes)

### Prerequisites
- Linux server (Ubuntu 22.04+ recommended), 2 CPU / 4 GB RAM minimum
- A domain with an A record pointing to the server IP
- A GitHub/GitLab repo for this code (fork or import)
- `kubectl`, `vault` CLI on your local machine

---

### Step 0 — Clone and configure

```bash
git clone <your-repo-url>
cd gitops-cluster

./bootstrap/configure.sh \
  https://github.com/YOUR_ORG/gitops-cluster \
  cluster.example.com \
  admin@example.com

git commit -am "Configure cluster"
git push
```

`configure.sh` rewrites every `REPO_URL_PLACEHOLDER`, `CLUSTER_DOMAIN_PLACEHOLDER`,
and `ACME_EMAIL_PLACEHOLDER` in the repo. **Commit and push before the next step.**

---

### Step 1 — Install k3s + ArgoCD

Run on the server (requires root):

```bash
sudo REPO_URL=https://github.com/YOUR_ORG/gitops-cluster ./bootstrap/bootstrap.sh
```

This installs k3s (Traefik disabled — we manage it via GitOps), installs ArgoCD,
and applies the seed App-of-Apps. ArgoCD takes over from here.

Get the ArgoCD admin password:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Watch the platform come up:
```bash
kubectl get applications -n argocd -w
```

---

### Step 2 — Initialize Vault (one-time)

Wait until `kubectl get pods -n vault` shows `vault-0` Running, then:

```bash
./bootstrap/vault-init.sh
```

This initializes Vault with 1 unseal key and saves it to `.secrets/vault-init.json`.
**Back this file up outside the repo** (1Password, AWS Secrets Manager, etc.).

On every server restart, Vault will be sealed and needs:
```bash
UNSEAL_KEY=$(cat .secrets/vault-init.json | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
kubectl exec -n vault vault-0 -- vault operator unseal "${UNSEAL_KEY}"
```

---

### Step 3 — Configure Vault (one-time)

```bash
ROOT_TOKEN=$(cat .secrets/vault-init.json | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
VAULT_TOKEN="${ROOT_TOKEN}" ./bootstrap/vault-configure.sh
```

Configures Kubernetes auth + KV-v2 secrets engine.

---

## Accessing Services

| Service  | URL                                      | Notes                         |
|----------|------------------------------------------|-------------------------------|
| ArgoCD   | `https://argocd.CLUSTER_DOMAIN_PLACEHOLDER` | admin / see Step 1            |
| Vault    | `https://vault.CLUSTER_DOMAIN_PLACEHOLDER`  | use root token from Step 2    |
| Traefik  | Enable dashboard in `platform/traefik/values.yaml` |                      |

TLS uses the `selfsigned` ClusterIssuer by default. Switch to `letsencrypt-prod`
by changing the `cert-manager.io/cluster-issuer` annotation on ingresses once your
DNS is resolving and port 80/443 are reachable.

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

Commit and push — ArgoCD syncs automatically. No kubectl needed.

---

## Upgrading Platform Components

Change the `targetRevision` in the relevant `platform/*/application.yaml` and push.
ArgoCD applies the upgrade. To pin to an exact version, replace `7.8.*` with `7.8.3`.

---

## Production Checklist

- [ ] Switch Vault from file storage to Raft + auto-unseal (AWS KMS / Azure Key Vault)
- [ ] Set `server.replicas > 1` in ArgoCD values for HA
- [ ] Enable Traefik dashboard behind auth middleware
- [ ] Switch cert-manager issuer from `selfsigned` to `letsencrypt-prod`
- [ ] Set up external backup for `.secrets/vault-init.json`
- [ ] Add Prometheus + Grafana to `applications/` for observability

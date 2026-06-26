import json

providers = json.load(open("/tmp/providers.json"))

def find_scope(s):
    if s.get("managed"):
        return f'!Find [authentik_providers_oauth2.scopemapping, [managed, {s["managed"]}]]'
    return f'!Find [authentik_providers_oauth2.scopemapping, [name, {json.dumps(s["name"])}]]'

# Build the oidc-apps blueprint body
lines = []
lines.append("version: 1")
lines.append("metadata:")
lines.append("  name: oidc-apps")
lines.append("  labels:")
lines.append('    blueprints.goauthentik.io/description: "OIDC providers + applications (GitOps)"')
lines.append("entries:")
for p in providers:
    slug = p["slug"]
    env = f'OIDC_{slug.upper()}_CLIENT_SECRET'
    lines.append(f"  # ---- {p['name']} ----")
    lines.append("  - model: authentik_providers_oauth2.oauth2provider")
    lines.append(f"    id: provider-{slug}")
    lines.append("    identifiers:")
    lines.append(f"      name: {json.dumps(p['name'])}")
    lines.append("    attrs:")
    lines.append(f"      name: {json.dumps(p['name'])}")
    lines.append(f"      client_type: {p['client_type']}")
    lines.append(f"      client_id: {json.dumps(p['client_id'])}")
    lines.append(f"      client_secret: !Env {env}")
    lines.append(f"      sub_mode: {p['sub_mode']}")
    lines.append(f"      include_claims_in_id_token: {str(p['include_claims_in_id_token']).lower()}")
    lines.append(f"      authorization_flow: !Find [authentik_flows.flow, [slug, {p['auth_flow']}]]")
    lines.append(f"      invalidation_flow: !Find [authentik_flows.flow, [slug, {p['inval_flow']}]]")
    lines.append(f"      signing_key: !Find [authentik_crypto.certificatekeypair, [name, {json.dumps(p['signing_key'])}]]")
    if p["scopes"]:
        lines.append("      property_mappings:")
        for s in p["scopes"]:
            lines.append(f"        - {find_scope(s)}")
    else:
        lines.append("      property_mappings: []")
    lines.append("      redirect_uris:")
    for r in p["redirect_uris"]:
        lines.append(f"        - matching_mode: {r['matching_mode']}")
        lines.append(f"          url: {json.dumps(r['url'])}")
    lines.append("  - model: authentik_core.application")
    lines.append("    identifiers:")
    lines.append(f"      slug: {json.dumps(p['app_slug'])}")
    lines.append("    attrs:")
    lines.append(f"      name: {json.dumps(p['app_name'])}")
    lines.append(f"      slug: {json.dumps(p['app_slug'])}")
    lines.append(f"      provider: !KeyOf provider-{slug}")
    if p["meta_launch_url"]:
        lines.append(f"      meta_launch_url: {json.dumps(p['meta_launch_url'])}")
oidc_blueprint = "\n".join(lines) + "\n"

groups_blueprint = """version: 1
metadata:
  name: gitops-groups
  labels:
    blueprints.goauthentik.io/description: "Cluster groups (GitOps-managed)"
entries:
  - model: authentik_core.group
    identifiers:
      name: Grafana Admins
    attrs:
      name: Grafana Admins
"""

def indent(text, n=4):
    pad = " " * n
    return "\n".join((pad + ln) if ln else ln for ln in text.split("\n"))

cm = []
cm.append("# Custom Authentik blueprints (config-as-code), mounted via")
cm.append("# values.yaml blueprints.configMaps and auto-applied by the worker.")
cm.append("# oidc-apps.yaml is GENERATED from the live providers (scripts/gen-authentik-blueprints).")
cm.append("# Client secrets are NOT here — set via !Env, injected from the authentik-oidc-secrets")
cm.append("# Secret (platform/secrets/authentik-oidc-secrets.sops.yaml).")
cm.append("apiVersion: v1")
cm.append("kind: ConfigMap")
cm.append("metadata:")
cm.append("  name: authentik-blueprints")
cm.append("  namespace: authentik")
cm.append("data:")
cm.append("  gitops-groups.yaml: |")
cm.append(indent(groups_blueprint, 4))
cm.append("  oidc-apps.yaml: |")
cm.append(indent(oidc_blueprint, 4))

open("/home/tobbe/gitops-cluster/platform/authentik/blueprints-configmap.yaml", "w").write("\n".join(cm) + "\n")
print("wrote blueprints-configmap.yaml")

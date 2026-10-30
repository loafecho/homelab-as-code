# kubernetes/

GitOps source for a single-node kubeadm cluster: Cilium CNI with
kube-proxy replacement, Argo CD (app-of-apps), the Tailscale operator for
tailnet-only ingress, and External Secrets Operator reading from a
self-hosted Infisical.

## Layout

```
bootstrap/root.yaml                    # the ONLY hand-applied manifest: AppProject + root Application
bootstrap/kubeadm-config.example.yaml  # example kubeadm config (pod/service CIDRs, no kube-proxy)
apps/                                  # one Argo Application per unit, watched by root
infra/namespaces/                      # zone-aligned namespaces
infra/netpol/                          # default-deny + DNS baseline, one file per namespace
infra/rbac/                            # the `cluster` AppProject (self-managed copy)
infra/eso/                             # one SecretStore per namespace, Tailscale egress to the secrets host
infra/cilium/                          # Helm values; CNI stays outside Argo (bootstrap dependency)
workloads/ntfy/                        # push notifications, tailnet-only, per-topic ACL
workloads/steel-browser/               # headless browser API; public-internet-only egress
workloads/alloy/                       # node metrics -> external Prometheus
workloads/static-sites/                # Caddy serving preview sites from a PVC
workloads/portainer-agent/             # lets an external Portainer server manage the cluster
bin/sync-static-sites.sh               # load site content into the static-sites PVC
```

## Bootstrap

1. `kubeadm init --config bootstrap/kubeadm-config.example.yaml` (edited for your network).
2. Install Cilium with `infra/cilium/values.yaml` (see `infra/cilium/README.md`).
3. Install Argo CD out of band, pinned to a release, for example
   `kubectl create ns argocd && kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.1.0/manifests/install.yaml`.
4. Create the out-of-band secrets: the Tailscale operator OAuth client
   (`operator-oauth` in ns `tailscale`) and one Infisical machine-identity
   bootstrap Secret per namespace (`infra/eso/bootstrap-secret.yaml.example`).
5. `kubectl apply -f bootstrap/root.yaml`. Argo syncs `apps/` and self-heals
   everything else.

## Segmentation model

- Every workload namespace starts **default-deny** for ingress and egress
  (`infra/netpol/`), with DNS to kube-system allowed explicitly.
- Each workload adds the narrowest rule it needs. Ingress comes only from the
  `tailscale` namespace (the operator's proxies), so nothing is reachable from
  the LAN.
- Egress that names a host uses a `CiliumNetworkPolicy` with `toFQDNs`. Its
  DNS rule must live in the **same** policy: Cilium's L7 DNS proxy only learns
  names from lookups it is allowed to see (`workloads/ntfy/netpol.yaml`).
- `steel-browser` may reach the public internet on 80/443 and nothing else:
  its egress is written as the complement of the private, CGNAT/tailnet and
  link-local ranges, so a web page cannot drive it into the home network.
- API-server access from a pod needs Cilium entity selectors
  (`kube-apiserver`, `host`); a plain `ipBlock` never matches host identities.
- Each namespace reads secrets through its own Infisical machine identity, so
  one namespace's credentials cannot read another's project.

## Validation

CI runs `yamllint`, `kubeconform` (core kinds plus CRD schemas for Argo CD,
Cilium and ESO), and `scripts/tests/check-argo-apps.py`, which checks that every
Application points at a real directory, uses an allowed repo, and that every
manifest directory is owned by exactly one Application.

Images are pinned by digest. Values marked `example.com` or RFC 5737 addresses
are placeholders for your own names and network.

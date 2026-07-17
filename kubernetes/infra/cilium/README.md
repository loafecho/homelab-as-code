# Cilium: Helm-managed, not Argo-synced

The CNI is deliberately outside Argo CD: Argo itself needs a working pod
network to start. The values in this directory are the source of truth.

    helm upgrade --install cilium cilium/cilium --version 1.19.5 \
      -n kube-system -f kubernetes/infra/cilium/values.yaml
    kubectl -n kube-system rollout restart ds/cilium

`socketLB.hostNamespaceOnly: true` is load-bearing: without it, Tailscale
operator proxy pods (netfilter-DNAT'd traffic, no socket) bypass socket-LB
ClusterIP translation and forwarded connections die. It is the same class of
fix that service meshes such as Istio need.

The pod CIDR (`172.20.0.0/16`) and the service CIDR (`172.21.0.0/16`, set in
kubeadm) are example ranges inside 172.16.0.0/12; pick ranges that do not
overlap your LAN or tailnet.

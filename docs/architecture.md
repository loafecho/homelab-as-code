# Architecture

One Proxmox VE host runs every guest. The design splits responsibility by
layer, and each layer has exactly one tool that is allowed to change it.

| Layer | Owner | Where |
|---|---|---|
| Guest existence and shape (vmid, CPU, RAM, disks, NICs, pool) | OpenTofu | `opentofu/` |
| What runs inside a guest; host firewall; tailnet ACL | Ansible | `ansible/` |
| Workloads on the Kubernetes node | Argo CD (GitOps) | `kubernetes/` |
| Drift detection across all of the above | shell + Python gates | `scripts/` |

## Network

```mermaid
flowchart LR
  internet((Internet))
  admin[Admin devices<br/>LAN + tailnet]
  subgraph pve[Proxmox host]
    direction LR
    control[control<br/>Ansible, OpenTofu client]
    vault[vault<br/>Infisical, egress DROP]
    teleport[teleport<br/>access plane]
    media[media<br/>home services]
    kube[kube<br/>k8s node: Cilium, Argo CD]
    engine[engine<br/>SearXNG worker]
    email[email<br/>mail, sensitive]
    gateway[gateway<br/>DMZ, not built]
  end
  deploy[deploy box Pi<br/>OpenTofu + hardware key]

  admin -- "22 / 8006 break-glass" --> pve
  control -- "22 Ansible" --> vault & teleport & media & kube & engine
  control -- "8888 search" --> engine
  control -- "6443 kubectl" --> kube
  control & teleport & media & email -. "443 secret fetch, tailnet only" .-> vault
  deploy -- "8006 Proxmox API" --> pve
  internet -. "443 (disabled until built)" .-> gateway
  gateway -. "8096 (disabled)" .-> media
```

- **Default deny, east-west and intra-zone.** Every guest has
  `policy_in: DROP`; each allowed flow is one line of data in
  `ansible/inventory/host_vars/<guest>.yml`. `vault` also drops all egress
  except tailscaled's control and relay sessions, DNS and NTP, and it has no
  LAN secrets port at all: consumers reach it over the tailnet.
- **Rules match what actually listens.** Each guest's LAN listeners were
  captured with `ss -tulnp` (`scripts/capture-listeners.sh`), and
  `scripts/tests/check-fw-coverage.py` fails unless every one of them is
  allowed, a Proxmox built-in, or listed as intentionally closed with a reason.
  A port with no known client is opened to the management set only (admin
  devices, the control node and the deploy box).
- **Two break-glass paths that do not depend on the tailnet:** LAN SSH from
  two reserved admin addresses, and the hypervisor's :8006 console.
- **Tailnet as an admin door, not a service mesh.** The Tailscale ACL grants
  admin devices SSH/HTTPS/console and `tag:monitor` exactly one probe; the
  validator in `roles/tailscale_acl` fails if anything broader appears.
- **Inside the Kubernetes node** the host firewall is only the outer ring:
  namespaces are default-deny with Cilium policies, and ingress arrives only
  through the Tailscale operator.

## Change flow

1. Edit data (inventory, host_vars, `main.tf`, manifests). Never edit rendered
   output.
2. Render and review: `scripts/check-renders.sh` shows the firewall and ACL
   diff against committed baselines (and fails if any baseline directory goes
   unchecked); `scripts/fleet plan` shows the
   OpenTofu plan.
3. Apply deliberately: the firewall goes live only through
   `ansible/playbooks/apply-firewall.yml`, which refuses to run without a
   confirm phrase, one file at a time if wanted, with `scripts/fw-rollback.sh`
   armed on the hypervisor as a dead-man switch (it rolls back after N minutes
   or as soon as the conntrack table passes 50%); `fleet apply` only applies a
   saved plan; Argo CD syncs merged manifests.
4. Measure drift: `scripts/drift-check.sh` returns PASSED, DRIFT (a named
   host and field) or ERROR (could not measure). An unreachable host is never
   reported as clean.

## Secrets

No secret values are in this repository. The Proxmox API token and the
OpenTofu state key are age-encrypted to a hardware key and decrypted for one
command at a time. Kubernetes workloads read from Infisical through External
Secrets, one machine identity per namespace. Ansible reads the Proxmox token
from the environment, injected by the secrets manager for a single run.

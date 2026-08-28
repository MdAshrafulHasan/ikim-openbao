# Flux and GitOps: How I Bootstrapped It, and a Pattern I Kept Running Into

## Why manual bootstrap instead of `flux bootstrap`

The usual way to get Flux running is the `flux bootstrap github` CLI
command — one command, and it installs Flux's controllers and commits its
own sync config to your repo. I deliberately didn't use it. For a project
that's supposed to demonstrate GitOps discipline, running a single
imperative CLI command that does everything felt like it was hiding the
actual mechanics rather than showing them.

Instead, I generated the controller manifests as plain YAML with no
cluster side effects:

```bash
flux install --export > clusters/local/flux-system/gotk-components.yaml
```

and wrote the sync configuration myself — a `GitRepository` telling Flux
which repo and branch to watch, and a `Kustomization` telling it which
path to reconcile:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  ref:
    branch: main
  url: https://github.com/MdAshrafulHasan/ikim-openbao
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/local
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

That `Kustomization` points at the very folder that contains it — Flux
ends up watching and managing its own configuration from the moment it's
applied. Everything after this first `kubectl apply` is just a `git push`;
I never ran `kubectl apply` for infrastructure again after this point.

Applying it had to happen in two separate steps, not one — the CRDs in
`gotk-components.yaml` need to actually register with the API server
before the `GitRepository` and `Kustomization` objects in `gotk-sync.yaml`
can exist at all. Trying both in one pass fails with `no matches for kind`.
This turned out to be the first instance of a pattern I'd keep running into
for the rest of the project.

## The pattern: CRDs don't exist until their operator says so

Every operator I added after this — CloudNativePG, External Secrets
Operator, cert-manager — installs its own CRDs as part of its Helm chart.
If I tried to apply a custom resource from that CRD in the same Flux
`Kustomization` as the Helm chart itself, it would fail the same way,
because Kubernetes has no schema for that resource type until the chart
finishes installing.

The fix, once I recognized the shape of the problem, was always the same:
split the operator and anything that depends on its CRDs into two separate
Flux `Kustomization` objects, with the second declaring `dependsOn` on the
first.

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cnpg-operator
  namespace: flux-system
spec:
  path: ./infrastructure/postgres/operator
  # ...
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: pg-cluster
  namespace: flux-system
spec:
  dependsOn:
    - name: cnpg-operator
  path: ./infrastructure/postgres/cluster
  # ...
```

I hit this same failure with CloudNativePG first, then again with External
Secrets Operator's `SecretStore`, then again with cert-manager's
`ClusterIssuer`. By the third time, I stopped debugging it as a surprise
and started building every new component with this split from the
beginning, rather than discovering the race condition each time.

## A related lesson: it's not just CRDs

Later, with cert-manager, I hit a variant of the same underlying problem
that wasn't actually about CRDs at all. OpenBao's pods crash-looped
because they'd been scheduled and started *before* cert-manager finished
issuing the TLS certificate they depended on — a perfectly valid Secret
reference, pointing at a Secret that simply didn't exist yet at the moment
the pod first tried to mount it. Deleting the pods and letting them
recreate against the now-existing Secret fixed it immediately, with no
config change needed at all.

That's the broader version of the lesson: ordering problems in a
GitOps-managed cluster aren't limited to "does this CRD exist yet." Any
resource that depends on something another system generates
asynchronously — a cert, a token, a database being ready — carries the
same risk, and `dependsOn` (or, in that specific case, just knowing to
restart the pod) is the tool for it either way.

## What this looks like in the repo

```
clusters/local/
├── flux-system/
│   ├── gotk-components.yaml
│   ├── gotk-sync.yaml
│   └── kustomization.yaml
└── infrastructure.yaml       # every other Kustomization, with dependsOn wired explicitly
```

Every infrastructure component on this platform is registered in
`infrastructure.yaml` as its own `Kustomization`, rather than one giant
Kustomization applying everything at once. It's more files to maintain,
but it means a failure in one component (like the OpenBao anti-affinity
issue, or the ESO `SecretStore` apiVersion mismatch) stays isolated to that
one Kustomization's status instead of blocking everything else behind it —
which made debugging every individual issue in this project faster than it
would have been with one monolithic apply.

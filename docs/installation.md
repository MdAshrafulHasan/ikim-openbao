# Installation: Standing This Up From the Git Repo

This walks through getting the whole platform running from scratch, on a
Windows laptop, starting from nothing but this repository.

## Prerequisites

- Windows 10/11 Pro (Hyper-V support needed — Home edition can work but
  needs an extra manual step, see the note at the end)
- Administrator access
- Around 8GB RAM free for the cluster's workloads

## 1. Install WSL2 and enable virtualization

Docker Desktop needs WSL2, and WSL2 needs virtualization actually enabled —
not just supported by the CPU, but turned on.

```powershell
wsl --install
```

Reboot after this completes. Then verify:

```powershell
wsl --status
```

If you hit `HCS_E_HYPERV_NOT_INSTALLED` or a similar virtualization error
despite this succeeding, check whether the hypervisor is actually set to
launch at boot:

```powershell
bcdedit /enum | Select-String "hypervisorlaunchtype"
```

If it shows `Off`:

```powershell
bcdedit /set hypervisorlaunchtype auto
```

Reboot again — this is the one setting that's easy to miss even when every
other virtualization check looks fine.

## 2. Install Docker Desktop

Skip Chocolatey for this one — it's more reliable to download the
installer directly from docker.com and run it yourself rather than through
a package manager wrapper. Launch Docker Desktop afterward and wait for it
to report "running" in the system tray.

## 3. Install the remaining tools

```powershell
choco install kind kubernetes-cli flux git -y
```

Verify each landed correctly:

```powershell
kind version
kubectl version --client
flux version --client
git --version
```

## 4. Clone the repository

```powershell
git clone https://github.com/MdAshrafulHasan/ikim-openbao.git
cd ikim-openbao
```

## 5. Create the kind cluster

```powershell
kind create cluster --name devops-challenge --config kind-config.yaml
kubectl config use-context kind-devops-challenge
kubectl get nodes
```

All three nodes (1 control-plane, 2 workers) should show `Ready`.

## 6. Bootstrap Flux manually

This repo bootstraps Flux from committed, plain YAML rather than the
`flux bootstrap` CLI command — see
[docs/flux-gitops-bootstrap.md](./docs/flux-gitops-bootstrap.md) for why.
The manifests are already in the repo; this just applies them, in the
order they need to go in:

```powershell
kubectl apply -f clusters/local/flux-system/gotk-components.yaml
kubectl get crd | Select-String "toolkit.fluxcd.io"
kubectl apply -f clusters/local/flux-system/gotk-sync.yaml
```

The two-step apply matters — the CRDs in the first file need to register
before the `GitRepository` and `Kustomization` objects in the second file
can exist at all.

Confirm Flux is running and pulling from the repo:

```powershell
kubectl get pods -n flux-system
kubectl get gitrepository -n flux-system
kubectl get kustomization -n flux-system
```

Everything else on the platform is deployed by Flux from this point
forward — there's no more manual `kubectl apply` for infrastructure after
this step.

## 7. Wait for infrastructure to come up

```powershell
kubectl get kustomization -n flux-system -w
```

Watch until every Kustomization shows `READY: True`. This takes a few
minutes — Postgres, OpenBao, MinIO, ESO, and cert-manager all need to pull
images and initialize. Ctrl+C once everything settles.

## 8. Initialize and unseal OpenBao (manual, one-time)

This step genuinely can't be automated through GitOps — see
[docs/openbao-setup.md](./docs/openbao-setup.md) for why.

```powershell
kubectl exec -it openbao-0 -n openbao -- bao operator init -key-shares=5 -key-threshold=3
```

**Save the 5 unseal keys and root token this prints — they're shown
exactly once.** Then unseal all three nodes:

```powershell
kubectl exec -it openbao-0 -n openbao -- bao operator unseal   # x3, different keys
kubectl exec -it openbao-1 -n openbao -- bao operator raft join http://openbao-0.openbao-internal:8200
kubectl exec -it openbao-1 -n openbao -- bao operator unseal   # x3
kubectl exec -it openbao-2 -n openbao -- bao operator raft join http://openbao-0.openbao-internal:8200
kubectl exec -it openbao-2 -n openbao -- bao operator unseal   # x3
```

Confirm:

```powershell
kubectl exec -it openbao-0 -n openbao -- bao status
```

Want `Sealed: false`, `HA Mode: active`.

## 9. Configure OpenBao's database secrets engine

```powershell
kubectl exec -it openbao-0 -n openbao -- bao login
```
(paste your root token)

```powershell
kubectl exec -it openbao-0 -n openbao -- bao secrets enable database
```

Get the Postgres app-user password CNPG generated automatically:

```powershell
kubectl get secret pg-cluster-app -n postgres -o jsonpath="{.data.password}" | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
```

```powershell
kubectl exec -it openbao-0 -n openbao -- bao write database/config/pg-cluster plugin_name=postgresql-database-plugin connection_url="postgresql://{{username}}:{{password}}@pg-cluster-rw.postgres.svc.cluster.local:5432/appdb?sslmode=disable" allowed_roles="readonly" username="appuser" password="<paste-password-here>"

kubectl exec -it openbao-0 -n openbao -- bao write database/roles/readonly db_name=pg-cluster creation_statements="CREATE ROLE {{name}} WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO {{name}};" default_ttl=1h max_ttl=24h
```

`appuser` needs `CREATEROLE` for this to work — grant it against whichever
pod is currently primary:

```powershell
kubectl get cluster pg-cluster -n postgres
kubectl exec -it <primary-pod-name> -n postgres -- psql -U postgres -c "ALTER ROLE appuser CREATEROLE;"
```

## 10. Create the OpenBao tokens ESO needs

```powershell
kubectl exec -it openbao-0 -n openbao -- bao policy write eso-readonly -<<EOF (or via a local .hcl file + kubectl cp, see docs/external-secrets-operator.md)
kubectl exec -it openbao-0 -n openbao -- bao token create -policy=eso-readonly -period=24h
```

```powershell
kubectl create secret generic openbao-token -n external-secrets --from-literal=token=<paste-token>
```

Repeat for the push-secret path (`eso-push` policy, `kv-apps` KV mount) —
full commands in
[docs/demo-app-and-hpa.md](./docs/demo-app-and-hpa.md).

## 11. Verify everything

```powershell
kubectl get pods -A | Select-String -NotMatch "Running|Completed"
```

Empty result (just the header) means everything's healthy.

```powershell
kubectl get externalsecret -A
kubectl get pushsecret -A
kubectl get hpa -A
```

Everything should show `Ready`/`Synced`.

## Notes for anyone on Windows Home

Hyper-V isn't exposed through the normal Optional Features UI on Windows
Home, but it can still be enabled manually:

```powershell
DISM /Online /Enable-Feature /All /FeatureName:Microsoft-Hyper-V
```

Reboot, then continue from Step 1.

## If something doesn't come up cleanly

This environment runs on a laptop, and Docker Desktop restarts (from
sleep, updates, or just closing the laptop) leave the cluster in a state
that needs a specific recovery sequence — stale internal DNS, OpenBao
resealed, sometimes a stale `kubectl` context. See
[docs/daily-startup-runbook.md](./docs/daily-startup-runbook.md) for the
exact steps; this isn't a sign anything is actually broken, just a known
characteristic of running Kubernetes on top of a laptop's container
runtime rather than real infrastructure.
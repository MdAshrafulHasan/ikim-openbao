# Architecture Overview

This is the entry point for anyone reading this repo for the first time —
what I built, why, and where to find the detail on each piece.

## The brief

Deploy a production-oriented Kubernetes platform centered on OpenBao,
capable of syncing secrets into Kubernetes namespaces, built with GitOps
discipline and real evidence of the failure scenarios I thought about along
the way.

## What's running

```
┌─────────────────────────────────────────────────────────────┐
│  kind cluster (1 control-plane + 2 workers)                  │
│                                                                │
│  Flux (GitOps engine — everything below is applied by Flux,  │
│  not by hand, from this repo)                                │
│                                                                │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐  │
│  │ CloudNativePG │   │   MinIO      │   │  cert-manager    │  │
│  │ Postgres HA   │──▶│ backup target│   │  + Ingress-nginx │  │
│  │ (3 instances) │   └──────────────┘   └──────────────────┘  │
│  └───────┬───────┘                                            │
│          │ dynamic creds                                      │
│  ┌───────▼───────┐   ┌──────────────┐   ┌──────────────────┐  │
│  │   OpenBao     │──▶│ External     │──▶│  demo-app        │  │
│  │  HA (Raft)    │◀──│ Secrets Op.  │◀──│  (db-check + HPA)│  │
│  └───────────────┘   └──────────────┘   └──────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

| Component | What it does | Details |
|---|---|---|
| kind | Local multi-node Kubernetes cluster | — |
| Flux | GitOps engine — git is the source of truth for everything | [flux-gitops-bootstrap.md](./flux-gitops-bootstrap.md) |
| CloudNativePG | HA Postgres (3 instances), automated backups, tested restore | [postgres-backup-restore.md](./postgres-backup-restore.md) |
| MinIO | Local S3-compatible target for Postgres backups | [minio.md](./minio.md) |
| OpenBao | HA secrets management (Raft storage), dynamic Postgres credentials | [openbao-setup.md](./openbao-setup.md), [ADR 0002](./adr/0002-openbao-storage-backend.md) |
| External Secrets Operator | Bidirectional sync between OpenBao and Kubernetes Secrets | [external-secrets-operator.md](./external-secrets-operator.md) |
| cert-manager + Ingress | TLS on OpenBao's listener and its externally exposed UI | [cert-manager-tls.md](./cert-manager-tls.md) |
| demo-app | Minimal proof workload consuming synced secrets, with HPA | [demo-app-and-hpa.md](./demo-app-and-hpa.md) |

## The one decision worth reading first

The brief asks for OpenBao with "high availability and PostgreSQL
backend" — those two things can't literally both be true, since Postgres
doesn't support the HA coordination OpenBao needs. [ADR 0002](./adr/0002-openbao-storage-backend.md)
covers how I resolved that: Raft for OpenBao's actual storage, and
Postgres brought in through OpenBao's database secrets engine instead —
dynamic, short-lived credentials rather than static storage. Everything
else on the platform builds on that decision.

## What I'd flag as known limitations, upfront

I'd rather list these here than have them discovered:

- **ESO's dynamic-secrets path has a client-side bug I isolated but didn't
  fix.** Static secret sync (`PushSecret`, and reading fixed KV values)
  works reliably. Reading OpenBao's *dynamic* database credentials through
  ESO specifically produces credentials that don't match what Postgres
  actually has, even though the same token and endpoint work correctly
  when called directly. Full isolation writeup in
  [external-secrets-operator.md](./external-secrets-operator.md).
- **OpenBao reseals on every pod restart**, requiring manual
  re-unsealing with the Shamir key shares. Correct, expected behavior for
  a system like this — but a real deployment would want auto-unseal via a
  cloud KMS to avoid needing a human every time.
- **Anti-affinity was relaxed for OpenBao's HA pods** to fit on a 3-node
  local cluster (1 control-plane + 2 workers isn't enough for hard
  one-pod-per-node isolation across 3 replicas). Documented in
  [openbao-setup.md](./openbao-setup.md) — a real deployment would want
  ≥3 dedicated worker nodes to keep that isolation guarantee intact.
- **Internal service traffic isn't fully TLS'd yet.** OpenBao's own
  listener and its externally exposed UI are TLS-secured; its outbound
  connections to Postgres and MinIO are still plaintext, and ESO's
  `SecretStore` still points at `http://`. Noted as follow-up work in
  [cert-manager-tls.md](./cert-manager-tls.md).

None of these are things I didn't notice — they're documented because I'd
rather show I found and understood them than have them look like they
were missed.

## Repo layout

```
clusters/local/          # Flux's own bootstrap + every Kustomization registration
infrastructure/           # Postgres, OpenBao, MinIO, ESO, cert-manager, ingress-nginx, metrics-server
apps/demo-db-check/       # The proof-of-concept workload
docs/                     # Everything linked above
docs/adr/                 # Architecture decisions
```

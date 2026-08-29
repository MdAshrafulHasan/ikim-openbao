# ikim-openbao

A production-oriented Kubernetes platform built around OpenBao — GitOps
deployment via Flux, HA Postgres with automated backup and tested restore,
OpenBao issuing dynamic database credentials, and bidirectional secret sync
into Kubernetes via External Secrets Operator.

Built as part of a DevOps coding challenge. Everything here runs on a local
3-node kind cluster and is deployed entirely through Flux — after the
initial bootstrap, nothing in this platform was ever applied by hand.

## Start here

**[docs/architecture-overview.md](./docs/architecture-overview.md)** — what's
running, why, and links to the detail on every component.

**[docs/installation.md](./docs/installation.md)** — how to stand this up
yourself, from a clean machine to a fully running, verified platform.

## Stack

- **Kubernetes**: kind (3 nodes), Flux (GitOps)
- **Database**: CloudNativePG, PostgreSQL 17, MinIO (S3-compatible backups)
- **Secrets**: OpenBao (HA, Raft storage), External Secrets Operator
- **TLS**: cert-manager, ingress-nginx
- **Scaling**: metrics-server, HorizontalPodAutoscaler

## Repo layout

```
clusters/local/       Flux bootstrap and every component's Kustomization
infrastructure/        Postgres, OpenBao, MinIO, ESO, cert-manager, ingress
apps/demo-db-check/    Example workload proving secret sync end-to-end
docs/                  Write-ups for every component, including what broke
docs/adr/               Architecture decisions
```

## Documentation index

- [Architecture overview](./docs/architecture-overview.md)
- [Installation guide](./docs/installation.md)
- [Flux / GitOps bootstrap](./docs/flux-gitops-bootstrap.md)
- [Postgres: HA, backup, and tested restore](./docs/postgres-backup-restore.md)
- [MinIO backup target](./docs/minio.md)
- [OpenBao: setup, unsealing, dynamic secrets](./docs/openbao-setup.md)
- [ADR 0002: OpenBao storage backend decision](./docs/adr/0002-openbao-storage-backend.md)
- [External Secrets Operator: bidirectional sync](./docs/external-secrets-operator.md)
- [cert-manager, TLS, and Ingress](./docs/cert-manager-tls.md)
- [Demo app and HPA](./docs/demo-app-and-hpa.md)

# OpenBao: Setup, Unsealing, and Dynamic Postgres Secrets

How OpenBao got deployed on this platform, how it was initialized and
unsealed, and how it's now issuing real Postgres credentials on demand. See
[ADR 0002](./adr/0002-openbao-storage-backend.md) for the reasoning behind
using Raft for storage and Postgres as an integration rather than a backend.

## The setup

Running the official **OpenBao** Helm chart, HA mode, 3 replicas, backed by
**Raft integrated storage** — no external dependency needed. Unsealing uses
Shamir's Secret Sharing: 5 key shares total, 3 required to unseal.

It's deployed through Flux, its own `Kustomization`, living in the `openbao`
namespace:

```
infrastructure/openbao/
├── namespace.yaml
├── helmrelease.yaml
└── kustomization.yaml
```

It doesn't have a hard `dependsOn` on Postgres in Flux, because the actual
database secrets engine configuration is a manual step done after
unsealing — not something GitOps touches (more on why below).

## A scheduling problem worth mentioning

The Helm chart's default HA config sets **hard pod anti-affinity** — no two
server pods on the same node, full stop. That's a reasonable default for a
real cluster, but it doesn't work on a 3-node kind setup: one node is the
control-plane (tainted, won't take regular pods), leaving exactly 2
schedulable nodes for 3 pods that each insist on having their own node. The
math just doesn't work.

The fix was to relax it — `server.affinity: ""` in the Helm values, which
strips out the anti-affinity rule entirely and lets pods share a node when
they need to. Worth being honest about what this trade-off actually costs:
in a real deployment, you'd want ≥3 dedicated worker nodes so a single node
failure can never take out more than one Raft member at once. Locally,
we're giving up some of that isolation guarantee in exchange for the thing
actually being runnable at all on a laptop.

## Getting it initialized and unsealed

This part is deliberately **not** automated through GitOps. The unseal keys
and root token are, quite literally, the keys to everything OpenBao will
ever protect — running that through a version-controlled, declarative
pipeline would undercut the entire point of splitting up that trust in the
first place. It's a manual, one-time, out-of-band step here, same as it
would be anywhere real.

```bash
# Initialize once: 5 key shares, 3 needed to unseal
kubectl exec -it openbao-0 -n openbao -- bao operator init -key-shares=5 -key-threshold=3
```

This prints 5 unseal keys and a root token, shown exactly once — copy them
somewhere safe immediately. In an actual production setup, each key would
go to a different trusted person, so no individual (or even a pair of them
colluding) could unseal it alone. For this project, all 5 stayed with the
one operator (me), kept out of git entirely.

```bash
# Unseal node 0 — run this 3 times with 3 different keys
kubectl exec -it openbao-0 -n openbao -- bao operator unseal

# Bring the other two nodes into the Raft cluster and unseal them too
kubectl exec -it openbao-1 -n openbao -- bao operator raft join http://openbao-0.openbao-internal:8200
kubectl exec -it openbao-1 -n openbao -- bao operator unseal   # x3

kubectl exec -it openbao-2 -n openbao -- bao operator raft join http://openbao-0.openbao-internal:8200
kubectl exec -it openbao-2 -n openbao -- bao operator unseal   # x3
```

All three nodes came back `Sealed: false`, and the HA status split exactly
the way it should — one active, two standby — which is good evidence this
is a genuine Raft cluster replicating state, not just three unrelated
instances that happen to be unsealed at the same time:

```
openbao-0 → active
openbao-1 → standby
openbao-2 → standby
```

## Wiring up dynamic Postgres credentials

```bash
bao secrets enable database

bao write database/config/pg-cluster \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@pg-cluster-rw.postgres.svc.cluster.local:5432/appdb?sslmode=disable" \
  allowed_roles="readonly" \
  username="appuser" \
  password="<appuser's password, from the pg-cluster-app secret>"

bao write database/roles/readonly \
  db_name=pg-cluster \
  creation_statements="CREATE ROLE {{name}} WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO {{name}};" \
  default_ttl=1h \
  max_ttl=24h
```

Pointing at `pg-cluster-rw` (CNPG's read-write service) rather than a
specific pod matters here — that service always follows whichever pod is
currently primary, so this keeps working through failovers without anyone
needing to update a connection string.

### The permission error, and why it's not a bug to work around

First attempt at pulling credentials failed outright:

```
ERROR: permission denied to create role (SQLSTATE 42501)
```

Made sense once I thought about it — `appuser` (the app-database owner CNPG
creates automatically) doesn't have `CREATEROLE` by default, and shouldn't,
as a matter of least privilege, unless something actually needs it. OpenBao's
database plugin issues real `CREATE ROLE` statements under the hood to mint
each credential, so the privilege has to be granted on purpose:

```sql
ALTER ROLE appuser CREATEROLE;
```

Calling this out explicitly rather than just quietly fixing it and moving
on, because it's a genuine security-relevant decision — `appuser` still
can't do anything beyond managing roles, but it can now do that, and that's
worth someone knowing about rather than discovering by accident later.

### And it actually works

```
$ bao read database/creds/readonly
lease_id           database/creds/readonly/5ucR7JSaDEmPN1hNi1kQjz01
lease_duration      1h
username           v-root-readonly-LS8upaJswiSYejwU3hOx-1787738807
password            <random>
```

Checked directly in Postgres, and it's really there, with the exact
expiration OpenBao said it would have:

```
$ psql -U postgres -c "\du"
v-root-readonly-LS8upaJswiSYejwU3hOx-1787738807 | Password valid until 2026-08-26 11:06:52+00
```

That's the whole point proven out — OpenBao isn't just holding static
secrets, it's actually creating and managing real, time-bounded database
access on request.

## What's still ahead

- **External Secrets Operator** — take these dynamically generated
  credentials and get them into application namespaces as real Kubernetes
  Secrets automatically, instead of someone running `bao read` by hand
  every time.
- **cert-manager / TLS** — OpenBao's listener has no TLS in front of it
  yet. That's the next hardening pass before calling this done.

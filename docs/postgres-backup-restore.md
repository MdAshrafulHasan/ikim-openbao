# Postgres: HA, Backups, and Restore

This covers how Postgres is set up on this platform, how backups work, and
how to actually get your data back if something breaks. Everything here has
been run for real, not just written down as theory.

## What we're running and why

We went with **CloudNativePG (CNPG)** to run Postgres. There are a few
Kubernetes-native Postgres operators out there — CNPG, the Zalando operator,
Crunchy's PGO — and CNPG won out mostly because it doesn't need anything
extra sitting alongside it. No separate etcd, no Patroni, no additional
moving parts. The operator handles HA and failover on its own, which keeps
the whole setup simpler to reason about.

The cluster runs **3 instances** — one primary, two replicas, streaming
replication between them. That's enough to survive losing a single node
without losing data, which felt like the right balance for a laptop-based
setup that doesn't have unlimited resources to throw at it.

For backups, CNPG ships with **Barman Cloud** built in, which can stream WAL
files and full base backups straight to any S3-compatible object store. We
didn't have a real cloud bucket to point it at, so **MinIO** runs inside the
cluster itself as a stand-in — same S3 API, zero cost, and it's a one-line
config change (`endpointURL`) to swap in real S3 or GCS later if this ever
needs to leave a laptop.

Backups are scheduled daily at 2 AM. That's a fairly relaxed RPO — fine for
this kind of dev/test workload — but it's worth noting that WAL archiving
runs continuously regardless of the schedule, so point-in-time recovery
granularity is much tighter than "once a day" would suggest.

Everything is wired together through Flux with explicit ordering: the
`pg-cluster` Kustomization won't even attempt to apply until both the CNPG
operator *and* MinIO report ready. Without that, you hit a real race
condition — Kubernetes has no idea what a `Cluster` custom resource even is
until the operator's CRDs land first, so trying to apply both at once just
fails outright.

## How backups are configured

The `Cluster` resource points at MinIO like this:

```yaml
backup:
  barmanObjectStore:
    destinationPath: "s3://postgres-backups/"
    endpointURL: "http://minio.minio.svc.cluster.local:9000"
    s3Credentials:
      accessKeyId:
        name: minio-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: minio-creds
        key: ACCESS_SECRET_KEY
    wal:
      compression: gzip
```

and the daily schedule:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: pg-cluster-daily-backup
  namespace: postgres
spec:
  schedule: "0 0 2 * * *"
  backupOwnerReference: self
  cluster:
    name: pg-cluster
```

One honest caveat: the MinIO credentials are sitting in a plain Kubernetes
Secret, committed to git in plaintext, right now. That's not great, and it's
not meant to stay that way — it's a deliberate shortcut to get backups
working before OpenBao and External Secrets Operator are in place. Once
those land, this secret gets replaced by an `ExternalSecret` pulling from
OpenBao instead.

## How to actually restore something

CNPG doesn't restore in place — it spins up a brand new `Cluster` object
that boots from a backup, rather than touching your live primary. That's a
good thing: a restore attempt can never make an already-bad situation worse,
because it's not going anywhere near the cluster that's still running.

**1. Find a backup to restore from**

```bash
kubectl get backup -n postgres
```

Make sure it shows `PHASE: completed`.

**2. Write a new Cluster manifest that recovers from it**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-cluster-restored
  namespace: postgres
spec:
  instances: 1
  storage:
    size: 2Gi
  bootstrap:
    recovery:
      backup:
        name: <backup-name>
```

**3. Apply it and watch it come up**

```bash
kubectl apply -f restore-test.yaml
kubectl get pods -n postgres -l cnpg.io/cluster=pg-cluster-restored -w
```

There's an init job called `full-recovery` that pulls the base backup and
replays WAL before the actual Postgres container starts. Takes a minute or
two depending on how much WAL there is to catch up on.

**4. Actually check the data, don't just trust that the pod is green**

```bash
kubectl exec -it pg-cluster-restored-1 -n postgres -- psql -U postgres -c "\l"
kubectl exec -it pg-cluster-restored-1 -n postgres -- psql -U postgres -d appdb -c "\dt"
```

**5. Tear it back down once you've confirmed it worked**

```bash
kubectl delete cluster pg-cluster-restored -n postgres
```

This isn't meant to run alongside the real cluster — it exists to prove
recovery works, then it's gone.

**We actually did this.** A restore was run against this platform on
2026-08-25. The new cluster came up healthy, and `appdb` showed up owned by
`appuser` — exactly matching the original. Not a guess, not a "should work
in theory" — a real, verified restore.

## Two things that actually went wrong (and what they taught us)

Worth writing these up honestly, because they're more useful than a clean
success story would be.

### The replica that wouldn't come back after a restart

At one point Docker Desktop needed a restart to fix an unrelated networking
issue, and that meant all three kind node containers — and every Postgres
pod on them — got killed and restarted at the same moment. CNPG noticed the
primary was gone mid-restart and promoted a new one, which moved the whole
cluster onto a new WAL timeline. One replica came back still holding WAL
state from the *old* timeline, and Postgres flatly refused to let it rejoin:

```
requested timeline 2 is not a child of this server's history
```

The fix wasn't to nurse that pod back to health — it was to delete its PVC
(not just the pod) and let CNPG rebuild it from scratch off the current
primary. It came back as a new pod ordinal rather than reusing the old one,
which is just how CNPG handles this, not a bug.

The real lesson here: once a replica's WAL history diverges from the
current primary, there's no clean way to reconcile it in place. You rebuild.
It's also a decent argument for why this laptop-based kind setup is a
genuinely different beast than production — a real multi-host cluster
wouldn't have three database instances go down simultaneously just because
someone restarted their laptop's container runtime.

### The backup that looked fine but couldn't actually be restored

The very first restore attempt failed with:

```
WAL not found
```

Turned out the backup being restored from had been taken right in the
middle of the timeline-divergence mess above — WAL archiving to MinIO was
probably still catching up or had a brief gap at that exact moment, and the
backup needed a WAL segment that never made it into the archive.

Taking a fresh backup once things had settled down fixed it immediately —
that one restored cleanly on the first try.

The takeaway that's worth keeping around: a backup finishing successfully
doesn't guarantee it's actually restorable — that depends on unbroken WAL
continuity, which is a separate thing entirely. A backup nobody's ever tried
to restore is really just an assumption. Test restores aren't a "nice to
have" — they're the only way you find out a backup was actually any good.

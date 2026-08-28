# MinIO: Local S3-Compatible Backup Target

## Why it's here

Postgres backups need an S3-compatible destination, and I didn't have a
real cloud bucket to point at for a local project. MinIO gives me the same
S3 API without needing an external account — the only thing that changes
if this ever moves to real cloud storage is the `endpointURL` in the CNPG
backup config.

## What I tried first, and why I dropped it

I started with the Bitnami Helm chart, same as most of my other
components. It failed on image pull:

```
Failed to pull image "docker.io/bitnami/minio:2024.12.18-debian-12-r1": not found
```

Bitnami restructured how they distribute container images and pulled most
versioned tags from free access, keeping only a rolling `latest` for many
images. The chart's default pinned tag simply didn't exist anymore — not a
config mistake on my part, an external change I had no control over.

Rather than fight the chart's defaults, I dropped Helm for this one
component entirely and wrote plain manifests against the official
`minio/minio` image instead — maintained directly by MinIO Inc., not a
third-party repackaging, and much less likely to disappear under me again.
For something this small (a Deployment, a PVC, a Service), Helm's
templating wasn't buying me much anyway.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              value: admin
            - name: MINIO_ROOT_PASSWORD
              value: minioadmin123
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-data
```

Single replica — MinIO here is only a backup target, not a workload that
needs its own HA story. The interesting resilience question in this
project belongs to Postgres, not to where its backups happen to land.

## The bucket had to be created explicitly

Since I wasn't using Helm's `defaultBuckets` value anymore, nothing created
the `postgres-backups` bucket automatically. I added a one-time Job that
runs the `mc` CLI to create it, rather than doing it by hand — keeps the
whole setup reproducible from git instead of relying on something I did
manually once and might forget to redo if the cluster ever gets rebuilt:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-bucket
  namespace: minio
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: minio/mc:latest
          command:
            - /bin/sh
            - -c
            - |
              mc alias set local http://minio.minio.svc.cluster.local:9000 admin minioadmin123
              mc mb --ignore-existing local/postgres-backups
```

## Known shortcut, not hidden

MinIO's root credentials sit in a plain Kubernetes Secret, committed to git
in plaintext. That's not where I want this to stay — it's the same
deliberate trade-off I made with several early secrets on this platform,
to get things working before OpenBao and ESO existed to manage them
properly. Once those were in place, the plan was for this to become an
`ExternalSecret` sourced from OpenBao instead of a static value in git.

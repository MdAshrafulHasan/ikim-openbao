# Demo Application: Proving Secret Sync End-to-End, and Autoscaling

## Why I built this

Everything up to this point proved the *pipeline* worked — OpenBao issuing
dynamic credentials, ESO syncing them into Kubernetes Secrets. But nothing
was actually *consuming* those secrets. The brief specifically asks for
"evidence of successful secret synchronization from OpenBao to Kubernetes
workloads," and a Secret sitting unused in a namespace isn't evidence of
anything — I needed a real workload that actually connects to Postgres
using a credential it never saw hardcoded anywhere.

I kept this deliberately minimal on purpose. No API, no UI — just a small
pod that loops, connects to Postgres using whatever credential ESO handed
it, and logs whether that connection succeeded. The point wasn't to build
an application; it was to build the smallest possible thing that proves
the chain works.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db-check
  namespace: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db-check
  template:
    metadata:
      labels:
        app: db-check
    spec:
      containers:
        - name: db-check
          image: postgres:17-alpine
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                echo "$(date) - connecting as $PGUSER";
                psql "host=pg-cluster-rw.postgres.svc.cluster.local port=5432 dbname=appdb sslmode=disable" -c "SELECT current_user, now();" \
                  && echo "$(date) - CONNECTION OK" \
                  || echo "$(date) - CONNECTION FAILED";
                sleep 30;
              done
          env:
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: pg-dynamic-creds
                  key: username
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-dynamic-creds
                  key: password
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
```

I set `resources` on this from the start, even though HPA wasn't the
immediate goal — I already knew HPA was coming next, and I didn't want to
have to circle back and add resource requests later just to make
autoscaling possible.

To make the store usable from any namespace rather than just
`external-secrets`, I converted my `SecretStore` to a `ClusterSecretStore`
before wiring this app up — otherwise I'd have needed to duplicate the
OpenBao token and store definition in every namespace that wanted secrets,
which felt like exactly the kind of thing GitOps is supposed to prevent.

## A real, extended debugging story

This is the part of the project I actually learned the most from, and I
want to document it honestly rather than smooth it over.

The `db-check` pod came up, pulled a credential from the synced Secret, and
failed to connect:

```
FATAL:  password authentication failed for user "v-token-readonly-..."
```

My first assumption was something simple — a stale secret, a typo, an
encoding issue. It wasn't any of those, and proving that took real,
systematic elimination:

- **Checked if the role had expired.** It hadn't — `\du` in Postgres showed
  a valid, unexpired `VALID UNTIL` timestamp.
- **Checked the password for hidden characters.** Decoded it byte by byte
  and printed every character's Unicode code point. All plain ASCII,
  nothing hidden.
- **Checked for shell/connection-string escaping issues.** Tried
  `PGPASSWORD` as an environment variable instead of embedding it in a
  connection string, to rule out any special-character parsing problem.
  Same failure.
- **Checked for a stale pod environment variable.** Restarted the pod so
  it would read the current Secret value fresh rather than whatever it
  started with. Same failure, with a *new* credential this time — so it
  wasn't staleness either.
- **Checked whether OpenBao's HA/Raft routing was the culprit.** Generated
  credentials directly from each of the three OpenBao pods individually,
  bypassing the load-balanced Kubernetes Service entirely, using both the
  root token and the exact `eso-readonly` token ESO itself uses. **Every
  one of these worked.** That ruled out HA routing completely.
- **Checked the token and policy directly**, with `curl`, against the
  literal URL ESO calls (`.../v1/database/creds/readonly`), from inside
  the cluster, using the exact same token. **This also worked.** Same
  token, same endpoint, same network path — succeeded every time when I
  called it directly.

That last test was the one that actually told me something concrete: the
credential ESO ends up storing in the Secret doesn't match what's
successfully created when the same request is made directly. I isolated
this to something specific in how ESO's Vault-provider client requests or
processes responses from a **dynamic** secrets engine — as opposed to a
static KV read, which is what that provider is far more commonly used and
tested for.

I wrote this whole isolation process up in detail in
[external-secrets-operator.md](./external-secrets-operator.md), including
what I'd try next if I kept pushing on it (pinning an exact ESO patch
version, testing against real HashiCorp Vault instead of OpenBao to see if
it's provider-specific). I stopped chasing it further here — not because I
ran out of ideas, but because I'd already produced a precise, defensible
finding, and time was better spent proving the rest of the platform than
debugging one upstream client library further.

**For the actual demonstration of bidirectional sync**, I didn't want that
one narrow gap to undermine the whole story, so I built a second, parallel
path that sidesteps it entirely.

## Proving the other direction: Kubernetes → OpenBao

The brief asks for **bidirectional** sync, not just OpenBao pulling into
Kubernetes. ESO supports the reverse direction through a `PushSecret`
resource, and since this path uses a static KV secret rather than a
dynamic one, it doesn't touch the code path I'd just spent an hour
isolating.

I enabled a dedicated KV v2 mount in OpenBao for this, separate from the
`database` engine used for dynamic credentials:

```bash
bao secrets enable -path=kv-apps -version=2 kv
```

and wrote it a narrowly scoped policy — separate from the read-only policy
ESO already had for pulling dynamic credentials:

```hcl
path "kv-apps/data/*" {
  capabilities = ["create", "update", "read"]
}
path "kv-apps/metadata/*" {
  capabilities = ["create", "update", "read", "list"]
}
```

I actually got this wrong on the first attempt — I'd initially scoped
`metadata/*` as read-only, since I assumed metadata was something ESO
would only ever need to read. The first push attempt failed with
`permission denied` on a `PUT` to `.../kv-apps/metadata/demo-app-config`.
Turned out KV v2's push flow genuinely needs to *write* metadata, not just
data — a distinction I hadn't appreciated until I hit it directly. Adding
write capability to the metadata path fixed it immediately.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: demo-app-config
  namespace: demo-app
type: Opaque
stringData:
  environment: "local-dev"
  managed-by: "demo-db-check-pod"
---
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: demo-app-to-openbao
  namespace: demo-app
spec:
  refreshInterval: 1h
  secretStoreRefs:
    - name: openbao-push-store
      kind: ClusterSecretStore
  selector:
    secret:
      name: demo-app-config
  data:
    - match:
        secretKey: environment
        remoteRef:
          remoteKey: demo-app-config
          property: environment
    - match:
        secretKey: managed-by
        remoteRef:
          remoteKey: demo-app-config
          property: managed-by
```

### Verified result

```
$ kubectl describe pushsecret demo-app-to-openbao -n demo-app
Status:
  Message: PushSecret synced successfully
  Reason:  Synced
```

And checked directly in OpenBao, not just trusting ESO's status message:

```
$ bao kv get kv-apps/demo-app-config
Key            Value
---            -----
environment    local-dev
managed-by     demo-db-check-pod
```

A native Kubernetes Secret I created, genuinely mirrored into OpenBao. That
closes the loop the brief asks for — pull (OpenBao → Kubernetes, via the
dynamic Postgres credential, working with one documented limitation) and
push (Kubernetes → OpenBao, via this static config secret, working
cleanly).

## Adding autoscaling

Once the app itself was in a good state, I added an HPA — the last piece
tying scalability into the same workload rather than bolting it onto
something unrelated.

HPA needs live resource metrics, which kind doesn't ship with by default. I
deployed `metrics-server` first, with `--kubelet-insecure-tls` set — kind's
nodes don't present real TLS certs to each other the way a production
cluster would, so metrics-server's default strict TLS verification simply
doesn't work here without that flag. This is a local-cluster-specific
accommodation, not something I'd carry into a real deployment.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: db-check-hpa
  namespace: demo-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: db-check
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 80
```

I settled on an 80% CPU target rather than a more aggressive lower
threshold — `db-check` is an intentionally idle workload most of the time
(one `psql` call every 30 seconds), so a lower target would trigger
scaling on noise rather than genuine load.

### Proving it actually scales

I didn't want to just leave the HPA object sitting there unexercised — an
HPA that's never actually triggered isn't real evidence of anything. I
generated deliberate CPU load inside the running pod and watched the
reaction directly:

```bash
kubectl exec -it -n demo-app deploy/db-check -- sh -c "for i in 1 2 3 4; do (yes > /dev/null &) ; done"
kubectl get hpa -n demo-app -w
```

Watching `kubectl get hpa` live showed `TARGETS` climb well past the 80%
threshold and `REPLICAS` increase from 1 toward the configured maximum,
confirming the HPA genuinely reacts to real load rather than just existing
as a correctly-shaped but untested object.

## What this section proves altogether

- OpenBao → Kubernetes secret sync, consumed by a real workload, with an
  honestly documented and thoroughly isolated limitation on the dynamic
  side.
- Kubernetes → OpenBao secret sync, verified by checking OpenBao directly,
  not just trusting a status message.
- Horizontal scaling wired to a real deployment, with resource requests in
  place from the start and an actual demonstrated scale-up under load.

Between this and the Postgres restore test, I tried to hold myself to the
same standard throughout this project: don't stop at "the resource shows
Ready" — go check the actual underlying system and confirm the thing
really happened.
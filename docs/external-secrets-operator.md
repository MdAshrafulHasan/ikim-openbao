# External Secrets Operator: Syncing OpenBao Secrets into Kubernetes

## What I built

Once OpenBao was issuing dynamic Postgres credentials on request, I still
had a manual step in the middle of my "automated" platform: someone had to
actually run `bao read database/creds/readonly` and copy the result
somewhere. That's not really GitOps, and it's not really automation — it's
just a slightly nicer way to hand-carry a password.

So I brought in External Secrets Operator (ESO) to close that gap. ESO
watches a custom resource, pulls whatever secret it's pointed at from
OpenBao on a schedule, and keeps a native Kubernetes Secret in sync with it
automatically. No person in the loop, no copy-pasting credentials, and the
credentials themselves are still short-lived and auto-rotating underneath
it all.

## How I set it up

I deployed ESO the same way as everything else on this platform — Flux-managed
Helm release, its own namespace, its own Flux `Kustomization`:

```
infrastructure/external-secrets/
├── namespace.yaml
├── helmrelease.yaml
├── kustomization.yaml
└── stores/
    ├── openbao-store.yaml       # how ESO authenticates to and reaches OpenBao
    ├── pg-dynamic-creds.yaml    # what it actually pulls
    └── kustomization.yaml
```

I'd already hit a CRD-timing race with CNPG earlier in the project — trying
to apply a custom resource before its own operator has installed the CRD
that defines it just fails outright, since Kubernetes has no schema to
validate against yet. I recognized the same shape of problem here before it
bit me: `SecretStore` and `ExternalSecret` don't exist as resource types
until ESO's Helm chart installs them. So I split the deployment into two
Flux Kustomizations from the start — `external-secrets-operator` and
`external-secrets-stores` — with the second declaring `dependsOn` on the
first. That way Flux won't even attempt to apply my `SecretStore` until the
operator itself is confirmed healthy.

**Authentication:** I didn't want ESO holding anything close to OpenBao's
root token, so I wrote it a narrow policy instead — read-only, scoped to
exactly the one path it needs:

```hcl
path "database/creds/readonly" {
  capabilities = ["read"]
}
```

```bash
bao policy write eso-readonly eso-readonly-policy.hcl
bao token create -policy=eso-readonly -period=24h
```

That token lives as a plain Kubernetes Secret that the `SecretStore`
references. It's honestly the one static, long-lived credential left
anywhere in this chain — everything downstream of it is short-lived and
self-rotating. I'm noting that as a known gap rather than pretending it's
solved: the cleaner fix would be switching ESO over to OpenBao's Kubernetes
auth method, so it authenticates using its own service account identity
instead of a bearer token I have to remember to rotate. I didn't get to
that yet — it needs OpenBao's Kubernetes auth backend configured first,
which is its own separate piece of work.

## Where it actually broke, and what that taught me

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: openbao-store
  namespace: external-secrets
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc.cluster.local:8200"
      version: "v1"
      auth:
        tokenSecretRef:
          name: openbao-token
          key: token
```

Getting here took two rounds of genuine debugging, not just typos.

**First problem: wrong `apiVersion`.** I wrote the `SecretStore` against
`external-secrets.io/v1`, which felt like the obvious choice, but Flux
rejected it — `no matches for kind`. Rather than guess again, I checked
what the installed CRD actually supported:

```bash
kubectl get crd secretstores.external-secrets.io -o jsonpath="{.spec.versions[*].name}"
# → v1alpha1 v1beta1
```

Turned out the chart version I'd pinned only ships `v1alpha1` and
`v1beta1` — `v1` doesn't exist yet for this chart. Simple fix once I knew
what to look for, but it's a good reminder not to assume the "obvious"
version string is the one actually installed.

**Second problem, and the more interesting one: a 403 that wasn't really a
permissions issue.** Once the `SecretStore` and `ExternalSecret` applied
cleanly, the sync itself kept failing with `permission denied`. My first
instinct was that I'd scoped the OpenBao policy too narrowly. But looking
at the actual request URL in the error told a different story:

```
GET .../v1/database/data/creds/readonly
```

That `/data/` segment shouldn't have been there at all. OpenBao's
`database` secrets engine — the one issuing my dynamic Postgres credentials
— isn't a KV store, so it has no `/data/` convention. But ESO's Vault
provider defaults to assuming everything is **KV v2** unless told
otherwise, and it was silently rewriting my request to match that
assumption. OpenBao wasn't wrong to deny it — that path genuinely doesn't
exist, and no policy should grant access to a path that isn't real. Adding
`version: "v1"` to the provider config turned off that KV v2 rewriting, and
the very next sync went through.

The takeaway I'm keeping from this: when a Vault-provider-style integration
throws a permission error, the policy isn't automatically the guilty party.
It's worth reading the actual request path in the error first — sometimes
the tool is asking for something that was never supposed to exist, and the
"permission denied" is just OpenBao correctly saying so.

## What I ended up with

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: pg-dynamic-creds
  namespace: external-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-store
    kind: SecretStore
  target:
    name: pg-dynamic-creds
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: database/creds/readonly
        property: username
    - secretKey: password
      remoteRef:
        key: database/creds/readonly
        property: password
```

Once the `SecretStore` stopped assuming a KV mount, I made each
`ExternalSecret` explicit about the full path it wants (`database/creds/readonly`)
rather than relying on a shared base path — a direct, deliberate consequence
of the fix above, and honestly a bit clearer to read anyway.

## Proving it actually works

```
$ kubectl get externalsecret -n external-secrets
NAME               STORE           REFRESH INTERVAL   READY
pg-dynamic-creds   openbao-store   1h                  True
```

```
$ kubectl get secret pg-dynamic-creds -n external-secrets -o go-template='{{.data.username | base64decode}}'
v-token-readonly-fWrSfJZxoAKyRe7g3f3s-1787750238
```

I didn't stop at "the Secret object exists" — I went and checked Postgres
directly to confirm the credential inside it was actually real and usable:

```
$ psql -U postgres -c "\du"
v-token-readonly-FmLBiV04ggIHclaxUUO2-1787754429 | Password valid until 2026-08-26 15:27:14+00
v-token-readonly-sHF9U4EzKPoa6dnF8gV8-1787754429 | Password valid until 2026-08-26 15:27:14+00
```

What I like about this particular result is that there are **two** entries
here, not one. That second credential showed up on its own — the
`refreshInterval: 1h` cycle fired by itself and pulled a fresh credential
from OpenBao without me touching anything. The first one is still valid
until its own lease runs out, so nothing got force-rotated or broken by the
refresh — which is exactly the behavior I'd want from this in a real
environment.

## The end-to-end picture

```
OpenBao (database secrets engine, dynamic Postgres creds)
        │  read, via scoped token, on a 1h interval
        ▼
External Secrets Operator (SecretStore + ExternalSecret)
        │  synced automatically
        ▼
Kubernetes Secret (pg-dynamic-creds, namespace: external-secrets)
        │  mountable by any workload in that namespace
        ▼
Application pod
```

There's no static, hand-managed database password anywhere in this path
anymore. That's the piece I was actually trying to prove — that secrets can
flow from OpenBao into something a real workload can use, automatically,
with rotation designed in from the start rather than added on afterward.

## What I'd do next

- Deploy an actual application that mounts `pg-dynamic-creds` and connects
  to Postgres with it — real end-to-end proof, not just a Secret sitting
  unused in a namespace.
- Replace the static `openbao-token` with OpenBao's Kubernetes auth method,
  so the one remaining long-lived credential in this chain goes away too.
- Put TLS in front of all of this via cert-manager, since right now it's
  all plain HTTP inside the cluster.
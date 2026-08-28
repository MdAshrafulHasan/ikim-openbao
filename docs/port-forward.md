# cert-manager and TLS: Securing OpenBao's Listener

## Why I did this

Everything on this platform up to this point — OpenBao, Postgres, ESO — was
talking over plain HTTP inside the cluster. That's fine for a first pass,
but the challenge brief explicitly calls for TLS-enabled service exposure,
and OpenBao specifically deserved it first: it's the one component holding
every other secret on the platform, so it's the last place I wanted
unencrypted traffic sitting around, even inside a private cluster network.

I brought in **cert-manager** to handle certificate issuance, and used a
**self-signed CA** rather than a public one. That's a deliberate choice, not
a shortcut I'm glossing over — this cluster has no public DNS and isn't
reachable from the internet, so something like Let's Encrypt simply isn't
an option here. A self-signed internal CA is the right, standard answer for
a private cluster, and it's the same pattern real internal platform teams
use for service-to-service TLS that never needs to be validated by an
outside party.

## How I set it up

I deployed cert-manager through Flux, the same way as everything else on
this platform:

```
infrastructure/cert-manager/
├── namespace.yaml
├── helmrelease.yaml
└── kustomization.yaml
```

By now I know the drill with CRD-timing races — I'd already hit this exact
problem with CNPG and again with ESO — so I split cert-manager into two
Flux Kustomizations from the start: one for the operator itself, one for
the `ClusterIssuer` resources that depend on cert-manager's own CRDs
existing first.

I created two issuers:

- **`selfsigned-bootstrap`** — a bare self-signed issuer, whose only job is
  to mint the root CA certificate itself.
- **`devops-challenge-ca-issuer`** — a `CA`-type issuer that uses that root
  certificate to sign everything else. This is the one every actual
  workload's `Certificate` resource points at.

That two-step chain — self-signed root, then a CA issuer built from it — is
the standard pattern for building your own internal certificate authority
with cert-manager, rather than every single service minting its own
unrelated self-signed cert with no common root to trust.

For OpenBao specifically, I updated its Helm values to mount the resulting
TLS secret and switch its listener to HTTPS:

```yaml
global:
  tlsDisable: false
server:
  extraEnvironmentVars:
    BAO_CACERT: /vault/userconfig/openbao-tls/ca.crt
  volumes:
    - name: userconfig-openbao-tls
      secret:
        secretName: openbao-tls
  volumeMounts:
    - mountPath: /vault/userconfig/openbao-tls
      name: userconfig-openbao-tls
      readOnly: true
  ha:
    raft:
      config: |
        listener "tcp" {
          address          = "[::]:8200"
          cluster_address  = "[::]:8201"
          tls_cert_file    = "/vault/userconfig/openbao-tls/tls.crt"
          tls_key_file     = "/vault/userconfig/openbao-tls/tls.key"
        }
        storage "raft" {
          path = "/openbao/data"
        }
```

`BAO_CACERT` matters here specifically — without it, the `bao` CLI and any
client talking to OpenBao has no way to trust the self-signed CA, and every
request would fail on certificate verification even though the server
itself is working correctly.

## Where it broke, and what I learned diagnosing it

I came back to this cluster after a restart and found all three OpenBao
pods in `CrashLoopBackOff` — a meaningfully different failure than the
"sealed but running" state I'd already gotten used to seeing after
restarts. This one meant the process wasn't even starting.

```
Error parsing listener configuration.
Error initializing listener of type tcp: error loading TLS cert:
open /vault/userconfig/openbao-tls/tls.crt: no such file or directory
```

My first assumption was that the certificate itself was broken or never
got issued. I checked directly:

```bash
kubectl get certificate -n openbao
kubectl get secret openbao-tls -n openbao
```

Both were fine — `Certificate` showed `READY: True`, and the `openbao-tls`
Secret genuinely had all three expected keys (`tls.crt`, `tls.key`,
`ca.crt`), correctly populated. So the certificate infrastructure itself
wasn't the problem, which ruled out my first theory quickly.

What I think actually happened: the OpenBao pods had been created and
scheduled **before** cert-manager finished issuing the certificate and
before the `openbao-tls` Secret existed. Kubernetes doesn't retroactively
attach a volume to an already-running pod just because the Secret it
references shows up later — the pod's volume mount was defined correctly,
but the container had already started (and kept restarting) against a
Secret that didn't exist yet at that point in time.

The fix was simple once I understood the cause — I didn't need to touch the
certificate or the config at all, just force the pods to restart cleanly
now that the Secret genuinely existed:

```bash
kubectl delete pod openbao-0 openbao-1 openbao-2 -n openbao
```

They came back healthy immediately, picked up the TLS secret correctly on
this fresh start, and moved to the expected "sealed but running" state
instead of crash-looping.

The lesson I'm taking from this, on top of the CRD-timing lesson I already
had from CNPG and ESO: **ordering problems in Kubernetes aren't limited to
CRDs and custom resources.** A perfectly valid Secret, referenced by a
perfectly valid volume mount, can still cause a crash loop if the pod
happened to start before the Secret existed and never got a reason to
retry the mount. Anywhere a workload depends on a Secret that another
system generates asynchronously (like cert-manager issuing a cert), there's
a real ordering risk worth thinking about — not just for the CRD itself,
but for anything that CRD subsequently creates.

## Proving it actually works

After re-unsealing all three nodes, I checked status on the current leader:

```
$ bao status
Sealed                  false
HA Cluster              https://openbao-0.openbao-internal:8201
HA Mode                 active
```

That `https://` in the `HA Cluster` address is the real proof here — before
this change, that same field showed a plain `http://` address. The internal
Raft cluster communication between OpenBao nodes is now genuinely
encrypted, not just the external-facing listener.

## Exposing it externally: Ingress + TLS

Internal TLS on OpenBao's own listener was a good first step, but it didn't
actually address the other half of what the brief asks for — a way to
reach a service *from outside the cluster* over HTTPS. Up to that point,
the only way I could talk to anything in this cluster was `kubectl exec`
or `port-forward` — there was no exposed, TLS-terminated endpoint at all.

I brought in **ingress-nginx** and pointed an `Ingress` resource at
OpenBao's UI, reusing the exact same CA issuer I'd already built for the
internal TLS work rather than standing up a second, unrelated trust chain.

I deployed the ingress controller as a `ClusterIP` service rather than
`NodePort` or `LoadBalancer`. kind doesn't provision real cloud load
balancers, and I didn't want to rebuild my kind cluster just to add a
`NodePort` mapping — my original cluster had never had a committed
`kind-config.yaml` with `extraPortMappings` in the first place, and
recreating the cluster at this point would have meant re-bootstrapping
Flux and losing time for no real benefit. `kubectl port-forward` into the
ingress controller does the same job for local development without any of
that disruption.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-ingress-tls
  namespace: openbao
spec:
  secretName: openbao-ingress-tls
  dnsNames:
    - openbao.local
  issuerRef:
    name: devops-challenge-ca-issuer
    kind: ClusterIssuer
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openbao-ui
  namespace: openbao
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - openbao.local
      secretName: openbao-ingress-tls
  rules:
    - host: openbao.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: openbao
                port:
                  number: 8200
```

The `backend-protocol: HTTPS` annotation mattered here specifically —
OpenBao's own listener only speaks TLS now (from the earlier work in this
document), so I had to tell nginx explicitly to talk HTTPS to the backend
rather than its default assumption of plain HTTP. Missing that would have
given me a working edge certificate with a broken connection behind it —
TLS on the outside, a failed handshake on the inside.

I registered this as its own Flux Kustomization with explicit `dependsOn`
on `openbao`, `ingress-nginx`, and `cert-manager-issuers` — three separate
systems all needed to exist before this could apply cleanly, and by this
point in the project I'd rather declare that dependency up front than
debug another `CrashLoopBackOff` or `no matches for kind` error after the
fact.

### Proving it actually works

```
$ kubectl get certificate -n openbao
NAME                  READY   SECRET
openbao-ingress-tls   True    openbao-ingress-tls
openbao-tls           True    openbao-tls

$ kubectl get ingress -n openbao
NAME         CLASS   HOSTS           PORTS
openbao-ui   nginx   openbao.local   80, 443
```

To actually test it end-to-end rather than just trusting the resource
status, I port-forwarded into the ingress controller and added a local
hosts-file entry so my browser would resolve `openbao.local` to my own
machine:

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8443:443
```

```
127.0.0.1 openbao.local   # added to C:\Windows\System32\drivers\etc\hosts
```

Then opened `https://openbao.local:8443` in a real browser. I got the
certificate warning I expected — my browser has no reason to trust my own
self-signed CA — but clicking through it landed me on OpenBao's actual UI,
served over HTTPS, routed through nginx-ingress, backed by a certificate
cert-manager issued from my own CA chain. That's the genuine external-facing
TLS story the brief was asking for, not just an internal-only
implementation of the same idea.

## What I'd still want to do

- **Update every client still pointing at OpenBao over `http://`.** ESO's
  `SecretStore` and `ClusterSecretStore` resources were configured before
  this change and still reference `http://openbao.openbao.svc.cluster.local:8200`.
  They technically still work right now because OpenBao's `tlsDisable`
  setting change didn't retroactively break existing plain-HTTP callers in
  my testing, but that's not something I want to rely on going forward —
  every internal caller should be updated to `https://` and given the CA
  cert to trust, the same way I did for the `bao` CLI via `BAO_CACERT`.
- **Extend TLS to Postgres and MinIO connections** — right now OpenBao's
  own listener is secured, but its connections *out* to Postgres
  (`sslmode=disable`) and MinIO (`http://`) are still plaintext. Worth
  doing as a follow-up pass once the client-side TLS updates above are
  settled.
- **Consider whether OpenBao's own root CA should be the same one issuing
  certs for other services**, or whether each major component should get
  its own trust chain. I went with one shared CA issuer for now, which is
  simpler to manage but means every service trusts the same root — a
  reasonable trade-off for a project this size, worth revisiting if this
  were ever headed toward production.
- **Move from `port-forward` to a real `kind-config.yaml` with
  `extraPortMappings`** if I ever rebuild this cluster from scratch —
  `port-forward` is fine for demonstrating the concept locally, but a
  committed, reproducible cluster config with a fixed NodePort mapping
  would be the more GitOps-correct way to expose this permanently rather
  than something I have to remember to run by hand each session.
- **Expose more than just OpenBao's UI through Ingress** — right now this
  pattern only covers one service. The same `Ingress` + shared CA approach
  would extend cleanly to anything else on this platform that eventually
  needs external access.
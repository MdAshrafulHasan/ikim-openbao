# ADR 0002: What "PostgreSQL Backend" Actually Means for OpenBao in My Setup

## Status
Accepted

## The problem I ran into

The challenge brief asks for "OpenBao configured for high availability with
PostgreSQL backend." Read literally, that sounds like: point OpenBao's
storage at Postgres. I started down that path in my head before realizing
it doesn't actually work.

OpenBao — a fork of Vault, same architecture underneath — only gets real HA
out of a small set of storage backends: mainly **Raft integrated storage**
or **Consul**. Postgres can technically be used as a storage backend, but
it doesn't support HA coordination at all. So "HA" and "Postgres as the
storage backend" can't both be true at the same time. I couldn't satisfy
the brief's wording literally and also satisfy the HA requirement it asks
for in the same sentence — they're in direct tension.

I didn't want to just quietly pick one interpretation and hope nobody
asked, so I'm writing this down as the decision it actually was.

## What I decided to do

- I used **Raft integrated storage** for OpenBao's actual HA storage, 3
  nodes. It's the standard, recommended way to run this in production, and
  it doesn't need anything extra bolted on to work.
- I brought Postgres into the picture through OpenBao's **database secrets
  engine** instead — OpenBao generates short-lived, scoped Postgres
  credentials on demand, against the real CNPG-managed `pg-cluster`, rather
  than storing OpenBao's own internal state there.

So instead of "Postgres backs OpenBao," what I built is "OpenBao backs
Postgres" — it actively manages access to the database rather than just
persisting its own data inside it. Looking back, I think this is actually
the more interesting thing to have built. Storing Vault/OpenBao's internal
state in Postgres wouldn't have demonstrated much of anything. Dynamic,
auditable, auto-expiring database credentials genuinely do.

## What this means for the rest of the platform

- OpenBao keeps full HA behavior — leader election, standbys, survives a
  single node dropping out with zero downtime. I verified this directly:
  one node active, two standby, and I watched the standbys pick up state
  correctly after I unsealed them.
- My applications don't need static, forever-lived Postgres passwords
  sitting in a Secret somewhere. They can ask OpenBao for credentials with
  a real TTL — I set `1h` default, `24h` max — and those just expire on
  their own.
- This also turned out to be exactly the seam External Secrets Operator
  needed. ESO pulls these dynamically generated credentials straight out
  of OpenBao and drops them into application namespaces as normal
  Kubernetes Secrets, refreshing them automatically as leases turn over —
  I built and tested that integration right after this decision, and it's
  documented separately.
- One thing I want to be upfront about rather than leave implicit: the
  `appuser` database role needed `CREATEROLE` granted before OpenBao's
  database plugin could actually mint new roles
  (`ALTER ROLE appuser CREATEROLE;`). That's a real, deliberate privilege
  grant I made, not something I want to gloss over. `appuser` still can't
  do anything beyond creating and managing roles, but it can do more than
  it could before, and I think that's worth someone knowing rather than
  discovering by accident later.

## What else I considered, and why I didn't go with it

**Just use Postgres as the storage backend and drop HA.** I ruled this out
quickly — it directly contradicts the "highly available" half of the same
requirement. Wasn't really a serious option once I understood the
trade-off.

**Use Consul as the storage backend instead of Raft.** I considered this
briefly, but Consul would need its own HA setup to actually be reliable,
which just moves the complexity somewhere else rather than removing it.
Raft ships built into OpenBao with nothing extra to run, so I couldn't find
a real upside to bringing Consul into the picture just for this.

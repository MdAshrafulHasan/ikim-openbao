# ADR 0002: What "PostgreSQL Backend" Actually Means for OpenBao Here

## Status
Accepted

## The problem

The challenge brief asks for "OpenBao configured for high availability with
PostgreSQL backend." Read literally, that sounds like: point OpenBao's
storage at Postgres.

The trouble is, that's not really a thing you can do and keep HA. OpenBao
(it's a fork of Vault, same architecture underneath) only gets real HA —
leader election, automatic failover, consistent state across nodes — from
a small set of storage backends, mainly **Raft integrated storage** or
**Consul**. Postgres can technically be used as a storage backend, but it
doesn't support HA coordination at all. So "HA" and "Postgres as the
storage backend" can't both be true at the same time. The brief is asking
for two things that don't fit together if you take the wording at face
value.

## What we did instead

- OpenBao's actual HA storage is **Raft integrated storage**, 3 nodes.
  This is the standard, recommended way to run it in production, and it
  doesn't need anything extra bolted on.
- Postgres shows up in the architecture through OpenBao's **database
  secrets engine** instead — OpenBao generates short-lived, scoped
  Postgres credentials on demand, against the actual CNPG-managed
  `pg-cluster`, rather than storing OpenBao's own internal state there.

So instead of "Postgres backs OpenBao," it's "OpenBao backs Postgres" — it
actively manages access to the database rather than just persisting its own
data in it. Honestly, this is the more interesting and more useful thing to
demonstrate anyway. Storing Vault/OpenBao's internal state in Postgres
doesn't really show off anything — dynamic, auditable, auto-expiring
database credentials genuinely do.

## What this means in practice

- OpenBao keeps full HA behavior — leader election, standbys, survives a
  single node dropping out without any downtime.
- Applications don't need static, forever-lived Postgres passwords sitting
  in a Secret somewhere. They can ask OpenBao for credentials with a real
  TTL (currently `1h` default, `24h` max) that just... expire.
- This is also exactly the seam External Secrets Operator plugs into next —
  ESO can pull these dynamically generated credentials out of OpenBao and
  drop them into application namespaces as normal Kubernetes Secrets,
  refreshing them as leases turn over.
- One thing worth being upfront about: the `appuser` database role needed
  `CREATEROLE` granted before OpenBao's database plugin could actually mint
  new roles (`ALTER ROLE appuser CREATEROLE;`). That's a real, deliberate
  privilege grant, not something to gloss over — `appuser` still can't do
  anything beyond creating/managing roles, but it's more than it had
  before, and that's worth documenting rather than leaving implicit.

## What else we considered

**Just use Postgres as the storage backend and drop HA.** Rejected —
directly contradicts the "highly available" part of the brief. Wasn't
really a serious option.

**Use Consul as the storage backend instead of Raft.** Rejected — Consul
would need its own HA setup to actually be reliable, which just moves the
complexity somewhere else instead of removing it. Raft ships built into
OpenBao with nothing extra to run, so there's no real upside to bringing
Consul into the picture here.

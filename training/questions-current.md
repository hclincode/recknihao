# Iter 312 Questions

Date: 2026-05-27
Topics: OPA row-filter alternative to per-tenant views at 200+ tenant scale (Q1) + pg_replication_slots safe_wal_size and restart_lsn vs confirmed_flush_lsn (Q2)

## Q1 — Multi-tenant row isolation at 200+ tenant scale

We're somewhere around 80 tenants right now and each one queries our Trino/Iceberg setup. Right now I have a separate view per tenant that filters down to their `tenant_id`, and OPA checks that you can only query your own view. Someone said that approach breaks down when we get to 200 or 500+ tenants. I sort of understand why — managing hundreds of view definitions sounds painful — but I'm not sure what the alternative looks like.

We have a single events table in Iceberg with a `tenant_id` column. At large tenant counts, is the view-per-tenant approach actually the problem, and if so what do people do instead? I've heard OPA can be configured to do something smarter but I don't understand what that means in practice.

## Q2 — Postgres replication slot monitoring: which columns to actually watch

We're running Debezium to stream our Postgres events table into Iceberg, and I'm trying to set up proper alerting on our replication slots so we never hit the situation where Postgres starts dropping WAL and the slot goes invalid.

I know `pg_replication_slots` has a `wal_status` column that can flip to `lost` — we want to alert before that happens. I've read that there's also some column that tells you directly how many bytes of headroom you have left before the slot is in danger. Is that real? And separately, I've seen references to two different LSN columns — `restart_lsn` and `confirmed_flush_lsn` — but I can't figure out which one I should use in my monitoring queries to actually measure how much WAL Postgres is holding onto for this slot. Can you walk me through what each of those columns means and which one matters for "are we about to lose this slot" monitoring?

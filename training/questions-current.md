# Iter 311 Questions

Date: 2026-05-27
Topics: $path hidden column bypass in multi-tenant Trino (Q1) + Postgres replication slot early-warning states and safe_wal_size (Q2)

## Q1 — Multi-tenant data isolation / hidden column bypass

We've been locking down our Trino setup so tenants can only query their own schema. Someone on the team said we should deny access to any table that starts with a dollar sign — like `$files` or `$snapshots` — to prevent tenants from peeking at underlying file paths. That sounds reasonable, but I'm not 100% sure it covers everything. Are there other ways a tenant could figure out what files are on disk without going through those metadata tables?

## Q2 — Postgres replication slot monitoring / early warning states

We set up monitoring on our Postgres replication slot — we're watching `pg_replication_slots` and alerting if `wal_status` goes to `lost`, because that's when the slot gets invalidated and we lose our CDC position. But I'm wondering if `lost` is already too late — like, is there a warning state before that where we still have time to intervene? Also, we have `max_slot_wal_keep_size` configured — is there a column that tells us exactly how much headroom we have left before the slot gets dropped?

# Iter 323 Questions

Date: 2026-05-27
Topics: OPA policy revocation latency (Q1) + First-run snapshot expiry after 6 months + clean_expired_metadata (Q2)

## Q1 — Multi-tenant analytics: OPA policy revocation latency

One of our customers just churned and things got a bit hostile — they're threatening to claim their data, and we need to completely cut off their access to the analytics system right now, not in an hour. We're running OPA to control who sees what in Trino. My question is: if I update the OPA policy to deny that tenant, how long does it actually take before their queries start getting blocked? Is there a chain of things that all have to happen before the denial kicks in, and is there any way to make sure they can't run even one more query the moment we flip the switch?

## Q2 — Iceberg table maintenance: first-run snapshot expiry + clean_expired_metadata

We've been running in production for about six months and realized we never set up any automated snapshot expiration. So we have six months of snapshots just sitting there on our Iceberg tables. We're using Trino 467. I know there's a procedure to expire old snapshots, but I'm nervous about running it for the first time — will it try to process all six months of history at once and either take forever or blow something up? Also, I've seen mentions of a `clean_expired_metadata` parameter somewhere but I'm not sure what it does or whether I need it.

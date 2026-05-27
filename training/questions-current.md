# Iter 327 Questions

Date: 2026-05-27
Topics: Multi-tenant analytics / OPA column masking — how to mask sensitive column values per tenant role (Q1) + Iceberg table maintenance / manifest diagnostics — how to check for a manifest bloat problem before running the fix (Q2)

## Q1 — Masking sensitive column values in Trino based on who's querying

We already have OPA set up for row-level security — every query against the `events` table gets filtered down to that tenant's rows automatically, and it works great. Now one of our enterprise customers is asking us to go further: non-admin users should only see the first four digits of credit card numbers stored in one column, and email addresses in another column should be partially obscured so non-admins can't read the real values. Admins on the same tenant should see the full data. I know OPA handles our row filtering, but I have no idea whether it can also control what value gets returned inside a column based on who's querying. Is there a way to configure Trino and OPA to mask column values like this, and if so, how does it actually work — does Trino do the masking, or does OPA return the masked value?

## Q2 — How do I check if our Iceberg table actually has a manifest bloat problem?

A few weeks ago someone on our team mentioned that if query planning gets slow on Iceberg tables, running `rewrite_manifests` can help because it consolidates a bunch of internal tracking files Iceberg builds up over time. Our query planning latency on the `events` table has been creeping up and I want to investigate before blindly running a maintenance procedure on a production table. Is there a way to see how many of those tracking files the table currently has, so I can decide whether `rewrite_manifests` is actually worth running? And is there a rule of thumb for what count is "too many" — like, at what point does it actually start hurting performance?

# Iter 313 Questions

Date: 2026-05-27
Topics: OPA columnMask for per-column PII redaction (Q1) + Cost model for analytical workloads at SaaS scale (Q2)

## Q1 — Column-level redaction with OPA in Trino

We already have OPA set up for row-level filtering — each tenant only sees their own rows in our events table, and that's working well. Now I have a new problem: that events table has some columns that contain PII, things like the end user's email address or their name. We want to give our customers access to their analytics data, but we can not show them their users' raw email addresses on the dashboard.

Right now I'm thinking about splitting the table — like having a "safe" version without the PII columns that we use for the public dashboard, and keeping the full table behind stricter access. But that means we're duplicating a lot of data and maintaining two copies. Is there a way to keep one table and just mask or blank out specific columns depending on who's querying — kind of like how OPA already controls which rows you see, but applied to specific columns instead?

## Q2 — Cost surprises as analytics scales

We're running our analytics queries against Postgres right now, and we're about to move to something like a data warehouse or lakehouse setup. I'm trying to build a rough cost model before we commit to anything, but I genuinely don't know what the billing surprises look like at our scale.

We have about 80 customers, roughly 500 million rows of event data, and queries run constantly throughout the day as customers load their dashboards. I've looked at Snowflake and BigQuery pricing pages and seen "per TB scanned" and "compute credits" — but I have no feel for what that actually translates to in dollars per month for a product like ours. Are there architectural decisions we could make early on that would dramatically reduce how much we get billed, or does the cost mainly just track with how much data and how many customers we have?

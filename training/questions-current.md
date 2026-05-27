# Iter 314 Questions

Date: 2026-05-27
Topics: OLAP vs OLTP — do we actually need a separate analytics stack? (Q1) + OPA column masking configured but silently not working — batchColumnMasks vs columnMask Rego rule name (Q2)

## Q1 — OLAP vs OLTP — do we actually need a separate analytics stack?

We're a B2B SaaS with about 80 customers. We have an `events` table in PostgreSQL with roughly 500 million rows — it logs everything users do in our product. Customers are starting to ask for things like "show me our usage trends over the last 6 months" and "how does our team compare to other customers in our tier." Right now those queries just time out.

Someone on the team said we need to move to a "different kind of database" because Postgres is an OLTP database and analytics needs an OLAP database. I don't actually know what those terms mean. Is this a real distinction that matters, or is it just marketing? Like, what's fundamentally different between the two — can't I just tune Postgres better with more indexes and bigger machines, or is there a point where that stops working?

## Q2 — OPA column masking is configured but masking isn't happening

We set up OPA column masking so that non-admin users can't see raw email addresses in our events table — they should get a hashed value instead. We followed what looked like the right setup: we pointed Trino at our OPA server using `batch-column-masking-uri`, and we wrote a Rego policy. When we run a query as a non-admin, we expect to see the hashed email, but we're actually getting the real email — no masking at all, and no errors either. Just... silently wrong.

We're not sure where the bug is. Our Rego policy has a rule called `columnMask` that returns the hash expression. Could the rule name itself be the problem? What rule name does the batch column masking endpoint actually expect to find in the Rego policy, and how is that different from the single-column endpoint?

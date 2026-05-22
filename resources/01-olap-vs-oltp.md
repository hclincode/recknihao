# OLAP vs OLTP: What's the Difference and Why It Matters for SaaS

> **Note:** The production environment in `prod_info.md` is not yet filled in. This resource gives advice for a generic SaaS setup. Once your stack is described, re-read this with your specific tools in mind.

---

## Concept in one sentence

**OLTP** (Online Transaction Processing) is your regular application database — it records individual events fast. **OLAP** (Online Analytical Processing) is a different class of system built to *ask questions across millions of those events at once*.

---

## Why it matters for SaaS

Every SaaS product runs on an OLTP database (Postgres, MySQL, etc.) to serve users — saving orders, updating records, checking balances. That works great for one row at a time.

The problem appears when your product manager asks: *"How many users completed onboarding last month, broken down by plan tier?"* Your OLTP database will answer that — slowly. It has to scan thousands or millions of rows, touch columns it doesn't need, and lock up resources that your live application also needs. As you scale, these analytical queries start degrading the user experience, or you start giving up and avoiding the question altogether.

OLAP systems are designed so those questions are *cheap*, fast, and don't compete with your application traffic.

---

## Concrete example

Imagine your SaaS has 500,000 user accounts and logs every feature interaction in a `events` table (50 million rows).

**OLTP query (what your app does):**
```sql
SELECT * FROM users WHERE id = 12345;
-- Returns 1 row. Milliseconds. Fine.
```

**Analytical query (what your BI dashboard needs):**
```sql
SELECT feature, COUNT(*), AVG(duration_ms)
FROM events
WHERE created_at >= '2024-01-01'
GROUP BY feature
ORDER BY COUNT(*) DESC;
-- Scans 50M rows. On Postgres: minutes. On ClickHouse or BigQuery: seconds.
```

On your production Postgres, that second query competes for disk I/O with every user currently using your product. On an OLAP system, it's isolated and optimized for exactly this shape of work.

---

## When to use OLAP / when not to

**Reach for OLAP when:**
- Analytical queries are noticeably slow on your production DB (>1–2 seconds for dashboard queries)
- You want to run reports without affecting application performance
- You're aggregating across millions of rows regularly
- Multiple stakeholders (data team, CS, execs) need to run ad-hoc queries
- You need to join data from multiple sources (app DB + Stripe + Mixpanel)

**Stick with OLTP (your regular DB) when:**
- You have fewer than ~1–5 million rows in the tables you're querying
- Analytics is rare and internal (you can afford to run it off-hours or on a read replica)
- Your product is early-stage and the overhead of a second system isn't worth it
- A Postgres read replica with a few good indexes solves your problem today

**The rule of thumb:** your OLTP database *can* do analytics; OLAP makes it *practical* at scale without hurting your users.

---

## Key terms defined

| Term | Plain meaning |
|---|---|
| **OLTP** | The database your app writes to constantly — optimized for fast single-row reads and writes |
| **OLAP** | A system optimized for scanning large amounts of data and computing aggregations |
| **Analytical query** | A question like "sum/count/average over all rows matching X" — as opposed to "fetch row with id=Y" |
| **Read replica** | A copy of your OLTP database that you can query without touching the primary; a lightweight first step before full OLAP |
| **Aggregation** | Collapsing many rows into a summary: SUM, COUNT, AVG, MIN, MAX |
| **HTAP** | Hybrid Transactional/Analytical Processing — newer systems that try to do both; useful to know the term, but most SaaS teams still separate the two |

---

## Summary

Your application database (OLTP) is optimized for serving users one request at a time. Analytical questions require scanning and summarizing huge amounts of data, which is what OLAP systems are designed for. As a SaaS product grows, the practical reason to add an OLAP layer is *protecting application performance* and *making analytics fast enough to actually use*.

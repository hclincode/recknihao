# Iter75 Q2 — Answer

**Question**: How do I write a conversion funnel query in Trino? I have events with `user_id`, `event_name`, `occurred_at`, `tenant_id`. Steps: landing_page_visit → account_created → email_verified → onboarding_completed → first_purchase. I want the % of users who complete each step after completing the previous one, in order.

---

## Answer

Your instinct is right — counting each event type separately and dividing is wrong. A funnel requires that the same user completed both step N and step N+1, in time order. Here's the correct pattern with working SQL.

### The correct pattern: CTEs + ordered JOINs

The query has three key ideas:
1. **CTEs** — build up each step as a named result set
2. **Ordered JOINs** — each step joins back to events for users who completed the previous step, with `occurred_at > previous_step_time`
3. **COUNT(DISTINCT user_id)** — count unique users, not event rows (a user visiting the landing page 5 times should count once)

### Working SQL (5-step funnel)

```sql
WITH step1 AS (
  -- Users who hit the landing page, with their first visit timestamp
  SELECT user_id, MIN(occurred_at) AS step_time
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme'
    AND event_name = 'landing_page_visit'
  GROUP BY user_id
),
step2 AS (
  -- Of step1 users, those who created an account AFTER visiting
  SELECT s1.user_id, MIN(e.occurred_at) AS step_time
  FROM step1 s1
  JOIN iceberg.analytics.events e
    ON e.user_id = s1.user_id
   AND e.tenant_id = 'acme'
   AND e.event_name = 'account_created'
   AND e.occurred_at > s1.step_time   -- must be AFTER landing page visit
  GROUP BY s1.user_id
),
step3 AS (
  -- Of step2 users, those who verified email AFTER creating account
  SELECT s2.user_id, MIN(e.occurred_at) AS step_time
  FROM step2 s2
  JOIN iceberg.analytics.events e
    ON e.user_id = s2.user_id
   AND e.tenant_id = 'acme'
   AND e.event_name = 'email_verified'
   AND e.occurred_at > s2.step_time
  GROUP BY s2.user_id
),
step4 AS (
  -- Of step3 users, those who completed onboarding AFTER verification
  SELECT s3.user_id, MIN(e.occurred_at) AS step_time
  FROM step3 s3
  JOIN iceberg.analytics.events e
    ON e.user_id = s3.user_id
   AND e.tenant_id = 'acme'
   AND e.event_name = 'onboarding_completed'
   AND e.occurred_at > s3.step_time
  GROUP BY s3.user_id
),
step5 AS (
  -- Of step4 users, those who made a purchase AFTER onboarding
  SELECT s4.user_id, MIN(e.occurred_at) AS step_time
  FROM step4 s4
  JOIN iceberg.analytics.events e
    ON e.user_id = s4.user_id
   AND e.tenant_id = 'acme'
   AND e.event_name = 'first_purchase'
   AND e.occurred_at > s4.step_time
  GROUP BY s4.user_id
),
counts AS (
  SELECT
    COUNT(DISTINCT s1.user_id) AS n1,
    COUNT(DISTINCT s2.user_id) AS n2,
    COUNT(DISTINCT s3.user_id) AS n3,
    COUNT(DISTINCT s4.user_id) AS n4,
    COUNT(DISTINCT s5.user_id) AS n5
  FROM step1 s1
  LEFT JOIN step2 s2 ON s1.user_id = s2.user_id
  LEFT JOIN step3 s3 ON s1.user_id = s3.user_id
  LEFT JOIN step4 s4 ON s1.user_id = s4.user_id
  LEFT JOIN step5 s5 ON s1.user_id = s5.user_id
)
-- Output: one row per step with user count and conversion rate to next step
SELECT 'landing_page_visit'   AS step, n1 AS users, NULL                              AS pct_from_prev FROM counts
UNION ALL
SELECT 'account_created',              n2,           ROUND(100.0 * n2 / NULLIF(n1,0), 1) FROM counts
UNION ALL
SELECT 'email_verified',               n3,           ROUND(100.0 * n3 / NULLIF(n2,0), 1) FROM counts
UNION ALL
SELECT 'onboarding_completed',         n4,           ROUND(100.0 * n4 / NULLIF(n3,0), 1) FROM counts
UNION ALL
SELECT 'first_purchase',               n5,           ROUND(100.0 * n5 / NULLIF(n4,0), 1) FROM counts;
```

### What each part does

**Each step CTE:** finds users who completed that event type *after* completing the previous step. The `MIN(occurred_at)` captures the first occurrence. The `occurred_at > s_prev.step_time` condition ensures time ordering — a user who purchased before completing onboarding (an edge case) doesn't count as an onboarding → purchase conversion.

**The `counts` CTE:** joins all steps back to `step1` using `LEFT JOIN`, so users who dropped off at any point contribute a NULL to the later steps. `COUNT(DISTINCT user_id)` over LEFT JOIN results correctly counts only users who made it to each step.

**The final `UNION ALL`:** formats as one row per step with the conversion rate from the previous step. `NULLIF(denominator, 0)` prevents division-by-zero if any step has zero users.

### Sample output

| step | users | pct_from_prev |
|---|---|---|
| landing_page_visit | 12,000 | NULL |
| account_created | 4,200 | 35.0 |
| email_verified | 3,100 | 73.8 |
| onboarding_completed | 2,400 | 77.4 |
| first_purchase | 800 | 33.3 |

This tells you: 35% of visitors create accounts, 73.8% of account creators verify email, etc. The biggest drop (33.3% of onboarded users actually purchase) is your biggest optimization opportunity.

### Common mistakes to avoid

| Mistake | Why it's wrong |
|---|---|
| Count each event type independently and divide | Assumes the same user base at each step — ignores dropoff |
| Use `COUNT(*)` instead of `COUNT(DISTINCT user_id)` | Counts event rows, inflates users who fired the event multiple times |
| Forget `occurred_at > previous_step_time` | Counts users who did steps in wrong order |
| Miss `tenant_id` filter on joined events table | Cross-tenant data leak |

### Adding a time window

Real funnel analysis usually scopes to a time window (e.g., users who started the funnel in the last 30 days):

```sql
-- In step1, add a date filter:
WHERE tenant_id = 'acme'
  AND event_name = 'landing_page_visit'
  AND occurred_at >= CURRENT_DATE - INTERVAL '30' DAY
```

Subsequent steps are automatically scoped because they JOIN from `step1` — only users who started within the window are included.

### Performance on Trino + Iceberg

Each CTE is a separate scan of the `events` table. Because the table is partitioned by `tenant_id` (the recommended pattern), Trino skips other tenants' files entirely. For very large tables (hundreds of millions of events), the query still completes efficiently because partition pruning limits the data scanned per step.

If the query takes more than a few minutes on a large dataset, consider pre-aggregating daily per-user step completion into a summary table, then running the funnel logic on the summary.

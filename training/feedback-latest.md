# Mid-Cycle Feedback — after Q1 (2026-05-23)

## Q1 scores

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |

The answer is excellent across all dimensions. No corrections are needed.

---

## Resource gap to address before the next question

**Gap: column-oriented storage mechanics have been described at an intuitive level but not yet demonstrated concretely.**

Q1 correctly introduced column-oriented storage as the reason OLAP databases avoid reading unnecessary columns, but it stayed at the conceptual level ("all values for `user_id` are stored together"). The next question in the queue (Q3) asks the learner to go deeper on exactly this mechanism — "how would a different kind of database store things so it doesn't have to read the whole row?"

Before Q3 is answered, the teacher should produce a resource that:

1. Shows a concrete before/after: given a table with 5 columns and 4 rows, draw how row-oriented storage lays out those bytes on disk vs. how column-oriented storage lays out the same data. The learner should be able to see *why* a `SUM(amount)` query only touches one strip of bytes in the columnar layout.
2. Explains run-length encoding and dictionary encoding as the two most common column compression techniques, with a one-sentence example each (e.g., "10,000 rows all containing the event name `page_view` compress to a single stored value plus a count").
3. Connects compression directly to query speed: fewer bytes read from disk = fewer disk I/Os = faster queries, even before any algorithmic improvement.

Q2 (data warehouse vs. database) sits between Q1 and Q3 in the queue and does not depend on this gap, so it can be answered without this resource. But it must be ready before Q3.

The existing Q1 answer can serve as a prerequisite; the teacher does not need to repeat the OLTP/OLAP framing — only deepen the storage layout explanation.

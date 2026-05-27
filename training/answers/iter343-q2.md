# Answer to Q2: hardConcurrencyLimit — Queue vs Reject Behavior (Iter 343)

When a free-tier customer hits `hardConcurrencyLimit`, their extra queries **do not fail immediately** — they queue up and wait. But once the queue itself fills up (controlled by `maxQueued`), *then* queries are rejected. This is a two-stage behavior, and you need different UI messages for each stage.

## Stage 1: Queued (not a failure — "your query is waiting")

When a customer submits their 3rd query and `hardConcurrencyLimit: 2`, that query enters a queue. From the customer's perspective:

- The HTTP response is 200 (not an error)
- Trino reports `stats.state = "QUEUED"`
- The client library (JDBC, Python trino client) keeps polling in a loop, waiting for the query to move to `RUNNING`
- Once one of the two running queries finishes, the queued query starts automatically
- The customer gets their result — just with added wait time

**UI message for Stage 1**: "Your query is waiting for resources. This may take a moment." Do NOT show an error. Keep polling.

## Stage 2: Queue full — QUERY_QUEUE_FULL (actual rejection)

`maxQueued` caps how many queries can wait in the queue at once. When the queue is full, the next submitted query is rejected immediately with error code `QUERY_QUEUE_FULL`.

Example with `hardConcurrencyLimit: 2` and `maxQueued: 5`:
- Up to 2 queries run concurrently
- Up to 5 additional queries wait in the queue
- The 8th query from that customer is rejected with `QUERY_QUEUE_FULL`

| Stage | HTTP status | Error code | What client sees |
|---|---|---|---|
| **Stage 1: Queued** | 200 | (none) | Client polls; appears slow. No exception. `stats.state = "QUEUED"` |
| **Stage 2: Queue full** | 200 | `QUERY_QUEUE_FULL` | Client raises `TrinoQueryError` immediately. Message: `Too many queued queries for "global.free_tier"` |

Note: Trino always returns HTTP 200 for query-level errors — the error lives inside the JSON body, not in the HTTP status code.

**UI message for Stage 2**: "Too many queries are queued for your account. Please try again in a few moments." This is the actual failure case.

## How to configure it

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "maxQueued": 200,
    "subGroups": [{
      "name": "free_tier",
      "hardConcurrencyLimit": 2,
      "maxQueued": 10,
      "softMemoryLimit": "10%"
    }]
  }],
  "selectors": [{
    "group": "global\\.free_tier",
    "user": "free-tier-.*"
  }]
}
```

This gives free-tier customers 2 concurrent slots and a queue of up to 10. The 13th simultaneous query from a free-tier customer gets rejected with `QUERY_QUEUE_FULL`.

## What to build in your UI

Two code paths based on what Trino returns:

1. **`stats.state == "QUEUED"` in the response**: Keep polling. Show a "waiting" spinner. No error.
2. **`error.errorCode.name == "QUERY_QUEUE_FULL"` in the response**: Fail the request. Show the retry message. No polling.

You can also monitor `queued_time_ms` in `system.runtime.queries` to see how long queries are waiting before they run — useful for tuning whether your `maxQueued` is too small.

## Summary

- `hardConcurrencyLimit` → queues extra queries, does not reject them
- `maxQueued` → caps the queue; when full, rejects with `QUERY_QUEUE_FULL`
- Stage 1 (queued): "your query is waiting" — not a failure
- Stage 2 (queue full): "your query failed, try again" — actual rejection

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`

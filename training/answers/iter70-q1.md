# Iter70 Q1 — Answer

**Question**: We run about 30 tenants on shared Trino and MinIO infrastructure. Right now I have no idea what each tenant is actually costing us — I can see total cluster CPU usage and total storage, but I cannot tell you whether Tenant A is responsible for 60% of our query load or whether Tenant B's data has quietly grown to be 10x larger than everyone else's. Management is starting to ask whether we should bill customers differently based on how much they actually use, or at least set per-tenant resource caps so a heavy user can't crowd out the rest. My question is: how do I even start measuring storage and query compute on a per-tenant basis? Is there something built into Trino or MinIO that tracks this kind of breakdown, or do I have to build instrumentation myself? And what would a useful output actually look like — like, what numbers would I report to management to say "here is what each customer costs us per month"?

---

## Answer

**The short answer:** You don't need to build instrumentation from scratch. Trino's built-in HTTP event listener captures the cost metrics you need (CPU, wall time, bytes scanned), and you store them in an Iceberg audit table. Storage tracking comes from Iceberg metadata tables. Together, these give you per-tenant breakdowns without any new tools.

### Part 1: Measuring Query Compute Cost Per Tenant

**What Trino gives you directly:**
Every query that completes generates an HTTP event payload (no plugin required) with these cost fields:
- `statistics.elapsedTime` — wall-clock time
- `statistics.cpuTime` — actual CPU processing time across all workers
- `statistics.totalBytes` — compressed Parquet bytes read from MinIO (the real I/O cost)
- `statistics.peakMemoryBytes` — peak memory usage

**How to set it up (one-time configuration):**

Create `etc/http-event-listener.properties` on the Trino coordinator:

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://audit-collector:8080/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
```

Reference it in `etc/config.properties`:
```properties
event-listener.config-files=etc/http-event-listener.properties
```

Restart the Trino coordinator. From that moment forward, every completed query posts a JSON event to your collector endpoint.

**Important parsing detail:** The time fields serialize as ISO-8601 duration strings like `"PT2.345S"`, not milliseconds. A naive `int(elapsedTime)` will crash. Parse them to milliseconds for storage:

```python
from datetime import timedelta
import re

def parse_iso8601_duration_to_ms(s: str) -> int:
    m = re.match(r"PT(?:(\d+)M)?(\d+(?:\.\d+)?)S", s)
    if not m:
        raise ValueError(f"unexpected duration: {s}")
    minutes = int(m.group(1) or 0)
    seconds = float(m.group(2))
    return int((minutes * 60 + seconds) * 1000)
```

**Create a cost-tracking Iceberg table** to store this data permanently:

```sql
CREATE TABLE iceberg.analytics.tenant_query_costs (
    query_id          VARCHAR,
    tenant_id         VARCHAR,
    wall_time_ms      BIGINT,
    cpu_time_ms       BIGINT,
    bytes_scanned     BIGINT,
    peak_memory_bytes BIGINT,
    error_code        VARCHAR,
    query_date        DATE
)
WITH (
    format = 'PARQUET',
    partitioning = ARRAY['day(query_date)']
);
```

Your HTTP receiver (a simple FastAPI service) parses the JSON payloads and writes rows to this table.

**What to report to management — sample queries:**

```sql
-- Top tenants by compute cost (last 30 days)
SELECT
    tenant_id,
    COUNT(*) AS query_count,
    ROUND(SUM(cpu_time_ms) / 3600000.0, 1) AS cpu_hours,
    ROUND(SUM(bytes_scanned) / 1073741824.0, 1) AS gb_scanned
FROM iceberg.analytics.tenant_query_costs
WHERE query_date >= CURRENT_DATE - INTERVAL '30' DAY
  AND query_state = 'FINISHED'
GROUP BY tenant_id
ORDER BY cpu_hours DESC;
```

This tells you: Tenant A ran 450 queries, burned 12.3 CPU-hours, and scanned 2.1 TB of data. Tenant B ran 85 queries, burned 0.4 CPU-hours, and scanned 18 GB.

### Part 2: Measuring Storage Cost Per Tenant

**For shared tables (one table holding all tenants), use Iceberg's metadata tables:**

```sql
-- Storage breakdown by tenant (assumes table partitioned by tenant_id)
SELECT
    partition.tenant_id,
    COUNT(*) AS file_count,
    ROUND(SUM(file_size_in_bytes) / 1073741824.0, 1) AS storage_gb
FROM iceberg.analytics."events$files"
GROUP BY partition.tenant_id
ORDER BY storage_gb DESC;
```

**Key caveat on storage:** Without running the Iceberg maintenance sequence (snapshot expiry + remove_orphan_files), old Parquet files linger on MinIO even after you think you've deleted a tenant's data. Run this weekly:

```sql
-- Spark SQL only
CALL iceberg.system.expire_snapshots(
  table => 'analytics.events',
  older_than => current_timestamp() - INTERVAL '7' DAY
);

CALL iceberg.system.remove_orphan_files(
  table => 'analytics.events',
  older_than => current_timestamp() - INTERVAL '1' DAY
);
```

Most teams don't do this and their storage bills creep up 20–30% per year even though raw data volume is flat.

### Part 3: What to Report to Management

A simple monthly report:

| Tenant | Queries/Month | CPU-Hours | GB Scanned | Storage GB |
|---|---|---|---|---|
| Acme | 18,000 | 450 | 2,100 | 125 |
| Beta | 4,200 | 35 | 195 | 8 |
| Charlie | 650 | 8 | 42 | 2 |

For on-prem budgets, report "Acme uses 45% of cluster CPU" rather than trying to assign hardware costs. The data immediately shows whether you should bill customers differently or apply resource caps.

### Part 4: Resource Caps (Noisy Neighbor Isolation)

Once you have per-tenant metrics, use Trino's **resource groups** to cap CPU, memory, and concurrent queries per tenant:

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "subGroups": [
        {
          "name": "tenant_acme",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "acme-service-account",
      "group": "global.tenant_acme"
    }
  ]
}
```

The `tenant_query_costs` audit table shows which tenants hit queue saturation — that's your signal to either expand capacity or adjust the cap.

### Next Steps

1. **This week:** Deploy the HTTP event listener and create the `tenant_query_costs` Iceberg table.
2. **Collect 2 weeks of baseline data** to see the actual distribution of load.
3. **Run the per-tenant cost queries** and report to management.
4. **Set initial resource group caps** based on what you observe.
5. **Run snapshot expiry and orphan cleanup weekly** to keep storage metrics honest.

The entire measurement system uses only tools already in your stack. No external billing platform needed.

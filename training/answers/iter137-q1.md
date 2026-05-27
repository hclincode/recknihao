# Iter137 Q1 — Answer

**Question**: "I was trying to debug why one of our Trino queries was slow, so I ran EXPLAIN on it and noticed it said something like 'files: 12 out of 847 total.' I didn't add any filter on a date range or tenant — the query was just `SELECT COUNT(*), SUM(amount) FROM events WHERE event_type = 'upgrade'`. So how is Trino skipping 835 files without reading them? Does it somehow know ahead of time which files don't contain any 'upgrade' rows? I thought to count rows you'd have to at least open every file and scan through it — what's actually happening physically here, and does this mean Parquet files store some kind of summary of what's inside them before the actual data?"

---

## What You're Seeing: File-Level Min/Max Pruning via Iceberg Manifests

What EXPLAIN shows as "files: 12 out of 847 total" is Trino using **file-level min/max statistics** stored in Iceberg's manifest files to skip 835 files before even opening them. This is not magic — it's metadata written at write time, read at query time.

Here's the complete chain of what happens physically.

---

## 1. Iceberg Manifests Store Per-Column Min/Max For Every Column

Iceberg doesn't track statistics only for partition columns — it tracks them for **every column in the table**. Each manifest file (a small metadata file listing all data files in a snapshot) contains entries like this:

```
data_file_1.parquet:
  - partition: {day=2026-05-25, tenant_id=acme}
  - record_count: 50000
  - lower_bounds: {
      event_id: "evt_001",
      event_type: "upgrade",       ← per-column min/max for EVERY column
      user_id: "u_10001",
      amount: 1000
    }
  - upper_bounds: {
      event_id: "evt_999",
      event_type: "upgrade",       ← even though event_type is NOT a partition column
      user_id: "u_50000",
      amount: 99999
    }

data_file_2.parquet:
  - partition: {day=2026-05-25, tenant_id=acme}
  - lower_bounds: { event_type: "login", ... }
  - upper_bounds: { event_type: "signup", ... }
```

The `lower_bounds` and `upper_bounds` maps include entries for **every field ID** in the table schema, not just partition columns. This is defined in the Iceberg table specification. Spark populates these when writing files by aggregating Parquet row-group statistics from the file footers.

---

## 2. How File-Level Pruning Actually Works

When you run `SELECT COUNT(*), SUM(amount) FROM events WHERE event_type = 'upgrade'`, Trino:

1. **Reads the manifest list** (a few kilobytes of metadata pointers).
2. **Reads each manifest file** (a few megabytes — not data files).
3. **Checks each file's bounds** against your filter. For each manifest entry, it asks: "Can `event_type = 'upgrade'` possibly be true in this file?"
4. **Applies the range check**:
   - `data_file_1`: lower_bound = `'upgrade'`, upper_bound = `'upgrade'`. Value 'upgrade' is in [`upgrade`, `upgrade`]. **Keep this file.**
   - `data_file_2`: lower_bound = `'login'`, upper_bound = `'signup'`. Can 'upgrade' be in [`login`, `signup`]? Alphabetically, `'upgrade'` > `'signup'`, so no. **Skip this file.**
5. **Result**: 835 files are skipped without being opened; only 12 files with ranges that might contain 'upgrade' are read.

**The key insight**: this is a comparison of your filter value against recorded metadata, not a scan of actual data. It happens at planning time, before any data file is opened.

---

## 3. This Works on Non-Partition Columns — But Only When Data Is Clustered

This is where most engineers get confused: **file-level pruning works on any column, not just partition columns — but only if the data within each file is physically clustered.**

If events arrive in random order (mixed event types spread across every file):

```
file_001.parquet (random write order):
  rows: login, upgrade, signup, upgrade, login, page_view ...
  lower_bound = 'login', upper_bound = 'upgrade'   ← wide range, spans all values
```

In this case, every file's range overlaps with 'upgrade', and **no files get skipped**. The manifest stats are technically correct, but useless for pruning.

**But in your case, 835 out of 847 files are being skipped.** That means your data IS clustered by event_type. This happens when:

- Your event stream batches by type (upgrade events are written in a burst, then login events, etc.).
- Your Spark ingestion sorts before writing (`repartitionByRange` or `sortWithinPartitions` on event_type).
- You've run a sort-order compaction job: `CALL iceberg.system.rewrite_data_files(table => 'analytics.events', strategy => 'sort', sort_order => 'event_type ASC')`.

When data is clustered, each file touches only 1–2 event types, the per-file min/max range is narrow, and most files can be proved to exclude 'upgrade'.

---

## 4. Parquet Row-Group Statistics: A Second, Finer-Grained Layer

Within each file that Trino does open, there's another pruning layer. Every Parquet file is divided into **row groups** (typically 128–256 MB chunks), and each row group stores its own min/max statistics in the **Parquet footer** (a trailing metadata block after the actual column data).

```
file_001.parquet (128 MB, split into 2 row groups):
  row_group_1 (64 MB):
    event_type: min='login', max='page_view'
    → prune this row group (no 'upgrade' in [login, page_view])

  row_group_2 (64 MB):
    event_type: min='signup', max='upgrade'
    → keep (upgrade IS in [signup, upgrade])
```

Even if a file passed the manifest-level check, Trino can skip row groups within it that provably don't contain 'upgrade'. This saves reading 64 MB of compressed column data per skipped row group.

**The two-layer hierarchy:**
1. **Iceberg manifest → file-level pruning**: eliminates whole files (each 128–256 MB) before opening them.
2. **Parquet footer → row-group pruning**: eliminates row groups within opened files.

Both layers apply automatically to every Trino query — you don't configure them separately.

---

## 5. The Full Metadata Chain: How Stats Get Written

```
1. Spark writes events to Parquet. Row-group min/max stats go into the Parquet footer.
2. After writing, Spark reads the Parquet footers and aggregates per-file min/max.
3. Spark registers the file in an Iceberg manifest with lower_bounds/upper_bounds.
4. At query time, Trino reads the manifest (not the data files) to decide what to open.
```

You don't write or manage these stats manually — they are populated automatically by the Spark/Iceberg writer.

---

## 6. Verifying With the `$files` Metadata Table

You can inspect exactly what min/max stats Iceberg stores for every file in Trino:

```sql
SELECT
  file_path,
  file_size_in_bytes,
  record_count,
  lower_bounds,
  upper_bounds
FROM iceberg.analytics."events$files"
ORDER BY file_size_in_bytes DESC
LIMIT 20;
```

This returns each file's lower_bounds and upper_bounds maps. You'll see something like:

```
file_path                           | lower_bounds            | upper_bounds
.../events/part-00001.parquet       | {event_type: 'upgrade'} | {event_type: 'upgrade'}
.../events/part-00002.parquet       | {event_type: 'login'}   | {event_type: 'page_view'}
.../events/part-00003.parquet       | {event_type: 'signup'}  | {event_type: 'upgrade'}
```

Count which files would survive the `event_type = 'upgrade'` filter:

```sql
SELECT
  COUNT(*) AS total_files,
  COUNT(*) FILTER (
    WHERE upper_bounds['event_type'] >= 'upgrade'
      AND lower_bounds['event_type'] <= 'upgrade'
  ) AS files_trino_must_read
FROM iceberg.analytics."events$files";
```

The ratio should match what EXPLAIN showed: 12 out of 847.

---

## Answering Your Original Questions

**"Does Trino somehow know ahead of time which files don't contain any 'upgrade' rows?"**

Yes. The manifest entry for each file recorded the min and max value for event_type at write time. Trino checks those bounds against your filter before opening any files.

**"I thought to count rows you'd have to at least open every file and scan through it."**

For a filter (WHERE clause), no — you only open files whose min/max range overlaps the filter. But you do have to read the actual column values to count and sum them; Iceberg can't skip those from manifest stats alone. Only the 12 files that might contain 'upgrade' are opened.

**"Does this mean Parquet files store some kind of summary of what's inside them before the actual data?"**

Yes. Every Parquet file includes a footer with min/max stats per row group per column. Iceberg aggregates those into file-level summaries in manifest files. When Trino reads the manifest, it reads summaries only — the actual Parquet data files are opened only for the files that survive the manifest check.

---

## Practical Implications for Your Stack

**Iceberg 1.5.2 + Spark + Trino 467 + MinIO:**

- Stats are written automatically — no special configuration needed.
- To *improve* pruning on event_type, run a sort compaction:

  ```python
  spark.sql("""
      CALL iceberg.system.rewrite_data_files(
          table      => 'analytics.events',
          strategy   => 'sort',
          sort_order => 'event_type ASC, occurred_at ASC'
      )
  """)
  ```

  After this, most files will have a narrow event_type range (ideally one type per file), and you'll see even fewer files scanned.

- **Bloom filters (Parquet-level):** For high-cardinality columns where min/max ranges are wide (e.g., `user_id`), Parquet supports Bloom filters in row-group footers. These give exact-match lookups (`WHERE user_id = 'u_12345'`) without scanning the column. Iceberg 1.5.2 supports enabling them via table properties:

  ```sql
  ALTER TABLE iceberg.analytics.events
  SET TBLPROPERTIES ('write.parquet.bloom-filter-enabled.column.user_id' = 'true');
  ```

- **The 12/847 ratio is healthy.** It shows your ingestion pattern already creates some natural clustering. A sort compaction will push that ratio lower (fewer files opened per query) if you want to optimize further.

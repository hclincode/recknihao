# Iter 278 Questions

## Q1 — Trino showing stale data after our Spark pipeline runs

We have a Spark job that runs every hour and writes new data files to our Iceberg table on S3. The problem is that when we query through Trino right after the job finishes, we're still seeing the old data — sometimes for 10 or 15 minutes. We have to either wait it out or restart the Trino coordinator to get fresh results, which is obviously not sustainable. Is there a setting or command we can run from within Trino itself to force it to pick up the new files without restarting the whole service? And if there's a config knob for how long it caches that file metadata, what's a reasonable value to set — does lowering it have a meaningful performance cost?

## Q2 — Limiting how many simultaneous queries Trino sends to Postgres

We connected Trino to our production Postgres database so analysts can join our operational data with the Iceberg stuff on S3. The problem is that sometimes five or six analysts run reports at the same time, and each one is firing a separate query straight through to Postgres. Our Postgres connection count spikes and we start seeing slowdowns on the application side. Is there a way to tell Trino "only send at most two or three queries to the Postgres catalog at any given time, and queue the rest"? I'd rather cap it in Trino than add more connection pool infrastructure if I can avoid it.

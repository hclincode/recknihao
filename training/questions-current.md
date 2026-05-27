# Iter 308 Questions

Date: 2026-05-27
Topics: Multi-tenant isolation with Trino views (Q1) + JSONB column promotion during Postgres→Iceberg ingestion (Q2)

## Q1 — How do I make sure customers can never see each other's data even if they write their own SQL?

We store all our customers' event data in one big table with a `tenant_id` column. Right now our app server always appends `WHERE tenant_id = ?` to every query, and we just trust that the code never forgets. We're moving to a setup where Trino sits in front of our data, and some customers will eventually be able to run their own queries or connect their own BI tools directly. How do I make sure a customer can physically never see another customer's rows — even if they write their own SQL? I heard something about "views" being able to help here, but I don't understand how a view stops someone from just querying the underlying table directly.

## Q2 — How do I actually promote JSONB fields into real columns during Postgres→Iceberg ingestion?

We have a `properties` JSONB column in Postgres that holds maybe 15–20 different keys depending on the event type — things like `plan_name`, `feature_flag`, `device_type`. We want to move this data into Iceberg for analytics. Someone on my team said we should "promote" those JSON fields into real columns during ingestion, not keep them as a JSON blob. That sounds right, but I don't actually know how to do that in practice — do we write a Spark job, use dbt, something else? And do we have to go back and reprocess all the old data, or can we only fix new rows going forward?

# Iter 304 Questions

Date: 2026-05-27
Topics: HLL varbinary cast retest (Q1) + Iceberg schema evolution (Q2)

## Q1 — HLL type error storing sketches in Iceberg

We're trying to store a daily pre-aggregated count of unique users in an Iceberg table so we can roll it up into 7-day and 30-day windows quickly, but our CREATE TABLE query is failing with something about the HyperLogLog type not being supported. What are we doing wrong, and what's the right way to store these sketches so we can actually merge them later when a customer queries their rolling 30-day active users?

## Q2 — Adding a column to a live Iceberg table with hundreds of millions of rows

When we need to add a new column to a live Iceberg table that already has hundreds of millions of rows, what actually happens to the old Parquet files? Does Iceberg have to rewrite all of them, or is there some way it handles this without touching existing data?

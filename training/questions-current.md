# Iter 316 Questions

Date: 2026-05-27
Topics: Postgres replication slot WAL bloat (Q1) + OPA decision log debugging for Trino access control (Q2)

## Q1 — Postgres replication slot WAL bloat

We set up Debezium to stream changes from our Postgres database into our data pipeline about two months ago. It's been working fine, but last week our ops team started getting disk-full alerts on the Postgres server itself — not the analytics side, but the actual production database. We haven't changed our data volume much. After some digging, we found something called a "replication slot" that seems to be holding onto a huge amount of stuff. What is that, what's causing the disk to fill up, and how do we stop it from happening again without just turning off our sync pipeline?

## Q2 — OPA decision log debugging for Trino access control

We've been using OPA to control which rows each of our customers can see in Trino. Now we're getting requests to also debug why a specific user got access to — or was blocked from — certain data. OPA apparently has some kind of decision log, but when I look at it the entries are massive and hard to search through. What's actually in those logs, how do I read them to figure out why a particular query was allowed or denied, and is there a smarter way to set this up so debugging access decisions doesn't take an hour every time?

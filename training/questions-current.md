# Iter 296 Questions

## Q1 — Quick dashboard prototyping without killing the database

We're building out a new analytics screen for customers — usage trends broken down by feature, time period, and team. Before we commit to the final query design, I want to test a few different aggregations against our event table, which has about 400 million rows in Iceberg. The problem is every exploratory query I run takes 3-5 minutes and makes me nervous about burning through compute costs just to figure out if the approach is even right. Is there a way to run these test queries against a representative sample of the data so I can iterate quickly, without waiting for a full scan every time? I've seen some mention of sampling in SQL docs but never used it in practice.

## Q2 — Moving from nightly data exports to something closer to real-time

Right now we copy data from Postgres to Iceberg once a night using a full table dump for most of our smaller tables, and a "only pull rows updated since yesterday" approach for the big ones. It mostly works, but we have a few enterprise customers who are starting to complain that their dashboards are 12-24 hours stale. One of them wants to see their usage metrics update within a few minutes. I've heard the term CDC thrown around — something about capturing every change as it happens — but I genuinely don't know what that involves compared to what we're doing now. How does CDC actually work, and how do I know if it's worth the added complexity versus just running our batch sync more frequently?

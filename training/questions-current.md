# Iter 285 Questions

## Q1 — Join between Iceberg and Postgres is slow even though I thought Trino was doing some optimization

We have a query that joins a large Iceberg table to a Postgres lookup table. The Iceberg side has about 80 million rows and we're joining on a customer ID column that has maybe 2 million distinct values. I was told Trino does something called "dynamic filtering" where it reads the Postgres side first, builds a list of matching IDs, and then uses that list to skip a ton of Iceberg files it doesn't need to scan. That sounded great, but in practice the query still takes way longer than expected and seems to be scanning most of the Iceberg data anyway.

Is there a point where the number of distinct join keys is so large that this optimization just stops working? Like, does Trino give up on building that filter list if it gets too big? And if so, is there anything I can tune to change that behavior, or do I need to rethink how the query is structured?

## Q2 — We want to cap how many Trino queries can hit our Postgres replica at the same time

Our Postgres replica is getting hammered when multiple analysts run federated queries at the same time — each one opens connections to Postgres and the replica falls over. We basically need a way to say "no more than, say, 5 of these Trino-to-Postgres queries can run concurrently, and anything extra should just queue up instead of failing."

I've seen references to "resource groups" in the Trino docs but I don't understand how to tie a resource group specifically to queries that go to Postgres versus queries that are purely against Iceberg. Is there a way to tag a query or route it into a specific group based on what data source it's hitting? And once I set this up, does Trino pick it up automatically or do I have to restart something?

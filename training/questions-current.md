# Iter 319 Questions

Date: 2026-05-27
Topics: OPA bundle management — policy distribution without restarts (Q1) + Schema drift monitoring — detecting Postgres/Iceberg column mismatch (Q2)

## Q1 — OPA bundle management: distributing policy updates without restarting OPA

We use OPA to control which rows each tenant can see in our analytics queries. Right now if I need to change a policy — say a customer gets a new data access agreement and I need to restrict what they see — I have to SSH into the OPA process and restart it to load the new rules. That's obviously terrible in production. I've heard there's a way OPA can pull down policy updates automatically, something called a "bundle," but I have no idea what that actually is or how it works mechanically. Like, where do the policy files live? How does OPA know to go fetch them? And what happens if the OPA instance gets behind — say it's still running old rules for a few minutes after I've pushed a change — is that a real security problem for us?

## Q2 — Schema drift monitoring: detecting Postgres/Iceberg column mismatch

We sync data from Postgres into our analytics pipeline on a schedule. It's been working fine, but I'm worried about a scenario I haven't figured out how to catch: what if a developer on the app team quietly drops a column from a Postgres table, or renames one, and our pipeline just keeps running and silently ignores that data or starts writing garbage? By the time a customer notices their dashboard is wrong, it's been broken for days. Is there a standard way to detect that the Postgres table structure has drifted away from what your pipeline expects, before it causes that kind of silent data loss? What should we actually be monitoring?

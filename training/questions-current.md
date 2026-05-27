# Iter 322 Questions

Date: 2026-05-27
Topics: Storage growth estimation with daily updates (Q1) + OPA cache-ttl-seconds revocation latency tradeoff (Q2)

## Q1 — Storage sizing: estimating storage growth with daily updates

We are trying to plan our MinIO capacity for the next six months and I am having trouble getting a handle on how much storage actually grows. Right now I can see how many rows we write per day, but I do not know how to turn that into actual bytes on disk in a way that accounts for snapshot history. Like, if we are doing a lot of updates to existing rows — say we update maybe 10% of our event records daily to mark them as processed — does that mean storage is basically growing linearly, or does it compound somehow the longer we keep history around? I want to build a spreadsheet estimate I can show my manager, so even a rough formula would help.

## Q2 — Multi-tenant analytics: OPA cache-ttl-seconds and revocation latency

We use OPA to control which tenants can see which data in our Trino queries, and it is working, but someone on the team raised a concern I had not thought about: apparently OPA can cache policy decisions for a while, so if we revoke a tenant's access — say they churn and we need to cut them off immediately — there might be a window where their queries still succeed because OPA already cached an "allow" decision. Is that actually how it works? And if so, how do we tune that? I am not sure what the right tradeoff is between keeping the cache for performance versus how fast revocations actually take effect.

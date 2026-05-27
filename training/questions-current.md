# Iter 328 Questions

Date: 2026-05-27
Topics: Multi-tenant analytics / OPA row-filter + column masking composition — do they conflict or interfere when both apply to the same user (Q1) + Iceberg table maintenance / $manifests diagnostics — correct column names to measure manifest file size and files-per-manifest (Q2)

## Q1 — Do my row-level security and column masking interfere with each other?

We have OPA doing two separate things now: row-level filtering that limits every tenant's query to their own rows, and column masking that hides credit card and email values for non-admin users. Both work fine in isolation — I tested them independently. But I'm not totally sure what happens when the same user hits a table and both rules apply at once. Does the row filtering run first, and then Trino applies the column masking on top of the already-filtered results? Or could one cancel out the other somehow? I'm specifically worried that maybe OPA short-circuits once it finds the row filter and stops evaluating the column masking policy, or that the order somehow matters and a non-admin could end up seeing unmasked values if their row filter already narrowed things down. Is this a real concern, or do they always both apply independently regardless of what the other is doing?

## Q2 — Which columns do I actually use in the $manifests table to measure manifest size?

Last iteration I tried writing a query against the `$manifests` metadata table to see how much overhead our manifests are creating, and I got a "Column not found" error because I used the wrong column name. I want to get this right before I run it again on production. Specifically, I want to sum up the total size of all manifest files — is that column called `manifest_length`, `file_size`, `length`, or something else? And I also want to compute the average number of data files tracked per manifest — is that `data_files_count`, `added_data_files_count`, or what? Can you give me the exact column names from `$manifests` that I should use for those two things, and maybe show me what the full query would look like so I don't get another runtime error?

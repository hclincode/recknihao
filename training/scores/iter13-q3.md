# Iter 13 Q3 — Trino query audit trail via HTTP event listener

## Question summary
A SaaS engineer needs to show an enterprise customer's security team a log of every query that ran against their data — who ran it and when. The question asks whether Trino has a built-in way to record this.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Config property names are correct per official docs (event-listener.name=http, http-event-listener.connect-ingest-uri, http-event-listener.log-completed, event-listener.config-files). However, the field table presents user, principal, query, queriedColumns, queryState as flat top-level JSON keys. The actual HTTP event listener JSON is nested: user and principal live under context (QueryContext), query and queryState live under metadata (QueryMetadata), and column information lives under ioMetadata.inputs[].columns. The field name queriedColumns does not exist in the SPI — the real path is ioMetadata.inputs[n].columns[]. An engineer who tries to parse event.user or event.queriedColumns from the raw JSON will get null. Additionally, http-event-listener.log-split=false references a feature (SplitCompletedEvent) that was removed from Trino in the version-430s range. These are meaningful inaccuracies for anyone writing a JSON parser against the event payload. |
| Beginner clarity | 4 | The explanation of what the HTTP event listener does is clear. The config example is readable and labeled. The field table gives a beginner a reasonable mental model of what information is captured, even if the field paths are wrong. The role-per-tenant → user field connection is a strong insight. The three delivery options (Loki, Filebeat/Fluentd, Iceberg audit table) are concrete and beginner-accessible. |
| Practical applicability | 5 | The config is runnable as written and will enable the HTTP event listener correctly. The three k8s delivery options are all compatible with the on-prem stack described in prod_info.md. The audit table DDL is actionable. The restart requirement is called out. An engineer can set this up from this answer. |
| Completeness | 4 | Covers the question: how to enable, what fields the auditor cares about, how to store/consume events on the production k8s stack, and how role-per-tenant ties into the audit identity. Missing: the JSON nesting structure, so an engineer parsing the raw payload will need to discover the nested paths themselves. Also missing: the removed log-split property is a minor red herring. The answer does not mention that queriedColumns can be empty if the query uses a wildcard SELECT * before column analysis (a known issue in Trino). |
| **Average** | **4.00** | |

## Topic updated

**Topic**: Multi-tenant analytics: isolating customer data in SaaS

- Prior avg: 3.750 (9 questions through iter 12)
- New score this question: 4.00
- New running avg: (33.75 + 4.00) / 10 = **3.775**
  Prior scores sum: 1.75 + 4.75 + 4.75 + 4.25 + 3.25 + 5.00 + 4.00 + 4.00 + 2.00 = 33.75
- Status: PASSED (3.775 >= 3.5 threshold, 10 questions asked)

## Key finding

The HTTP event listener config is correct and the delivery options are well-chosen for the production stack. The critical flaw is that the resource and answer present QueryCompletedEvent fields (user, principal, query, queriedColumns, queryState, createTime, endTime) as flat top-level JSON keys. They are not. The actual JSON is nested: user is at context.user, query is at metadata.query, queryState is at metadata.queryState, and column information is at ioMetadata.inputs[n].columns (not "queriedColumns"). An engineer parsing the raw JSON event body to build an audit pipeline will get null for all these fields until they discover the nesting.

## Resource gap

`resources/05-multi-tenant-analytics.md` — the "What each completed query sends" table should be replaced or supplemented with the actual nested JSON structure. Specifically:

1. Replace the flat field table with a note that fields are nested inside three objects: context (user, principal, remoteClientAddress), metadata (query, queryId, queryState), and ioMetadata.inputs[n] (catalogName, schema, table, columns[]).
2. Rename "queriedColumns" to "ioMetadata.inputs[n].columns[]" to match the actual SPI field name (QueryInputMetadata.getColumns()).
3. Remove or annotate http-event-listener.log-split=false — SplitCompletedEvent was removed from Trino around version 430 and is no longer emitted; this line is harmless but misleading.
4. Optionally add a minimal example JSON snippet showing the nesting so engineers know what to expect when their HTTP receiver gets a POST.

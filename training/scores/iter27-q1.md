# Iter27 Q1 Score

**Question**: One tenant's query monopolized the entire Trino cluster for 20 minutes. How do we configure Trino resource groups to give each tenant their own resource budget?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.75 |
| Practical applicability | 4.75 |
| Completeness | 5 |
| **Average** | **4.875** |

**Feedback**: Outstanding answer. Critical JWT-principal-matching detail correctly surfaced and emphasized: selector's `user` field matches JWT subject (`acme-service-account`) NOT Trino role name (`acme_role`) — explicitly called out as "the gotcha that catches most teams" and explains why silent misconfiguration happens. Full resource-groups.json with softMemoryLimit, hardMemoryLimit, maxRunningQueries, maxQueuedQueries is correct. Kubernetes ConfigMap + Pod spec mounting is practical for the on-prem k8s stack. Coordinator restart required for file-based config correctly noted (OPA avoids restart). Monitoring via `system.runtime.tasks` and Trino UI described concretely. Restaurant analogy is effective for beginners. Beginner clarity docked slightly: `schedulingWeight` and `schedulingPolicy: weighted` introduced without explanation of how weight translates to fair scheduling. Practical applicability docked slightly: tuning guidance ("if one tenant is larger, give them 30-35%") is directionally helpful but no rule for calculating initial limits from cluster size. HTML entities in code blocks.

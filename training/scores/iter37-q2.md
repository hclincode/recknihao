# Iter37 Q2 Score

**Question**: Updated `rules.json` on Trino coordinator to block tenant roles from `system.runtime.queries`. Pushed to coordinator node but tenants can still query it. What's wrong?
**Topic**: Multi-tenant analytics
**Date**: 2026-05-24

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 4 |
| Practical applicability | 4 |
| Completeness | 4 |
| **Average** | **4.00** |

**Feedback**: Correctly identifies root cause (file-based rules.json not hot-reloaded, requires coordinator restart). Correctly contrasts with OPA which hot-reloads without restart. Verification step (SELECT as tenant → Access Denied) included. Kubernetes ConfigMap note is practical bonus. Two gaps: (1) doesn't mention the opt-in `security.refresh-period` property that enables periodic polling as an alternative to full restart; (2) doesn't give the exact `kubectl rollout restart deployment/trino-coordinator` command — "restart the Trino coordinator pod" is directionally right but less actionable than the specific kubectl command for on-prem Kubernetes deployments.

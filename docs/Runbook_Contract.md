# Runbook Contract

This document describes the PowerShell runbooks that ship with Azure Policy Exemptions Auditor (APEA), including their parameters, expected Automation variables, and exit semantics.

## Start.ps1 (sanity check)

| Aspect | Details |
| --- | --- |
| Type | PowerShell 7.2 runbook |
| Parameters | None |
| Behavior | 1. Reads required Automation variables (`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `LOG_ANALYTICS_WORKSPACE_RESOURCE_ID`, `ARTIFACT_STORAGE_ACCOUNT_*`, `USER_ASSIGNED_MI_RESOURCE_ID`).<br>2. Authenticates with managed identity; if unavailable, uses the service principal stored in `SP_CLIENT_*` variables.<br>3. Confirms access to the artifact Storage account and Log Analytics workspace.<br>4. Emits a JSON payload describing the environment (subscription, tenant, authentication method, storage/workspace identifiers). |
| Outputs | JSON string written via `Write-Output`. Use job streams for additional telemetry. |
| Exit codes | `0` on success. Non-zero if authentication or resource validation fails. |

## KqlCollect.ps1 (Log Analytics comparison)

| Aspect | Details |
| --- | --- |
| Type | PowerShell 7.2 runbook |
| Parameters | `QueryA` (string, default sample query)<br>`QueryB` (string, default sample query)<br>`RetryCount` (int, default 3)<br>`RetryDelaySeconds` (int, default 5) |
| Behavior | 1. Authenticates with managed identity (fallback to `SP_CLIENT_*` variables).<br>2. Retrieves `LOG_ANALYTICS_WORKSPACE_RESOURCE_ID`, resolves the workspace GUID, and requests an OAuth 2.0 token for `https://api.loganalytics.io`.<br>3. Executes both KQL queries with retry/back-off (`429`, `5xx`, and common transient status codes).<br>4. Converts the primary result tables to object arrays and compares them with `Compare-Object`.<br>5. Writes a structured JSON payload containing query metadata, row counts, duration, summary, and authentication method. |
| Outputs | JSON payload: `{ queryA: {...}, queryB: {...}, diffSummary: string, ok: bool, ts: ISO8601, authMethod: string }`. |
| Exit codes | `0` when `ok = true`; `1` when differences are detected or execution fails. |

## Automation variables consumed

| Variable | Purpose |
| --- | --- |
| `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID` | Diagnostics and context selection. |
| `LOG_ANALYTICS_WORKSPACE_RESOURCE_ID` | Identifies the target workspace. |
| `ARTIFACT_STORAGE_ACCOUNT_NAME`, `ARTIFACT_STORAGE_ACCOUNT_RG` | Used by `Start.ps1` to validate storage access. |
| `USER_ASSIGNED_MI_RESOURCE_ID` | Documents the identity bound to the Automation Account. |
| `SP_CLIENT_ID`, `SP_CLIENT_SECRET`, `SP_TENANT_ID` | Optional fallback credentials when managed identity is unavailable. |

Adhering to this contract ensures runbooks remain composable and predictable across environments.

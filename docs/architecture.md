# Architecture

Azure Policy Exemptions Auditor is intentionally modular so the core logic can be reused beyond Azure Automation in future phases. This document explains the deployed components, how they interact, and the security assumptions.

## Component overview

| Component | Description | Key configuration |
|-----------|-------------|-------------------|
| Azure Automation Account | Hosts the PowerShell 7 runbooks, managed identity, schedules, and automation assets. | System-assigned managed identity, optional user-assigned identities, private endpoint, diagnostic logging. |
| Hybrid Runbook Worker | Executes the runbooks inside the customer VNet to reach private endpoints. | Windows VM joined to the Automation Hybrid Worker group, deployed to the provided subnet with private DNS resolution. The Custom Script Extension calls `install-hybrid-worker.ps1` to download, install, and register the agent with retries. |
| Storage Account | Stores raw and processed CSV reports. May be created or referenced if it already exists. | Blob container for policy outputs, optional private endpoint, lifecycle management (optional). |
| Application Insights / Log Analytics | Collects runbook job telemetry and diagnostics. | Linked workspace, diagnostic settings enabled from Automation Account. |
| Managed Identity RBAC | Grants least-privilege access required for KQL queries, storage operations, and Azure DevOps OAuth 2.0 flow. | Reader on subscriptions, Resource Graph Reader, Log Analytics Reader, Storage Blob Data Contributor. |
| Azure DevOps | Destination for Git commits that contain obsolete exemption reports. | OAuth 2.0 Authorization Code flow with offline access refresh token stored as encrypted Automation variable. |

## Data flow

1. **Trigger** – Terraform-generated Automation schedules (derived from each subscription’s CRON expression) or a manual run start `Start.ps1` with a subscription list.
2. **Authentication** – Runbook connects with managed identity using `Connect-AzAccount -Identity`. If a user-assigned identity ID list is provided, it selects the first available identity.
3. **Data collection** – For each subscription, `KqlCollect.ps1` executes two KQL queries (policy assignments/compliance and policy exemptions) against Azure Resource Graph or Log Analytics. Responses are serialized to CSV and uploaded to the Storage account.
4. **Analysis** – `CompareExemptions.psm1` parses the CSV files, identifies orphaned and expired exemptions, and generates a consolidated CSV report.
5. **Publication** – The consolidated report is pushed to Storage and Azure DevOps. `PublishAdo.psm1` performs an OAuth 2.0 refresh-token exchange to obtain an access token and issues a Git push REST call.
6. **Observability & resiliency** – Logs and metrics flow to Log Analytics/Application Insights. Failures are surfaced through runbook job status, custom error records, and structured diagnostics persisted in the dead-letter container alongside the offending CSVs.

## Security considerations

* **Identity only** – No secrets are embedded in the code. Azure credentials rely on managed identity, and Azure DevOps uses a refresh token stored as an encrypted Automation variable.
* **Network isolation** – Automation, Storage, and the Hybrid Runbook Worker rely on private endpoints with associated Private DNS zones (`privatelink.azure-automation.net`, `privatelink.blob.core.windows.net`). Provide existing VNet and subnet IDs to Terraform to lock down traffic to private IPs.
* **Least privilege** – Terraform assigns only the roles needed for KQL, storage, and DevOps publication.
* **Auditing** – Commits to Azure DevOps include subscription display names, IDs, timestamps, and the resulting commit ID is logged for traceability. Blob storage provides versioning/history if enabled.

## Extensibility roadmap

* Introduce Logic App Standard workflows that call into the same runbook modules.
* Enable Azure DevOps pipeline triggers that consume Blob uploads instead of direct commits.
* Publish dashboards using the collected CSV data.


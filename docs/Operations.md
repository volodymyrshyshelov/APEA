# Operations Guide

This guide covers common day-two tasks for Azure Policy Exemptions Auditor (APEA). The deployment remains idempotent—rerunning `scripts/deploy.ps1` reconciles infrastructure, Automation variables, and runbook content.

## Redeploy or update infrastructure

1. Pull the latest changes from source control.
2. Run the deployment script:

   ```pwsh
   pwsh ./scripts/deploy.ps1 -SubscriptionId <subscription-guid>
   ```

   The script will reuse existing resources tagged `ap.project = "APEA"`, refresh runbook content, and update Automation variables. No manual edits to `terraform.auto.tfvars` are required; it is regenerated on each run.

## Updating runbooks only

1. Modify the desired runbook under `runbooks/`.
2. Execute the publisher directly to avoid a full Terraform apply:

   ```pwsh
   pwsh ./scripts/publish-runbooks.ps1 -AutomationAccountName <name> -ResourceGroupName <rg>
   ```

   The script uploads all runbooks, enforces PowerShell 7.2 runtime, enables verbose/progress logging, and publishes the drafts. Include `-WithSchedule` if you want to ensure the daily schedule exists for the `Start` runbook.

## Rotating service principal credentials (fallback path)

If the deployment created an ephemeral service principal (managed identity was unavailable), credentials are stored in Automation variables:

- `SP_CLIENT_ID`
- `SP_CLIENT_SECRET` (encrypted)
- `SP_TENANT_ID`

To rotate:

1. Remove the existing variables in Azure Automation if they are no longer valid.
2. Rerun `./scripts/deploy.ps1` to create a fresh service principal and reseed the variables.

Managed identities do not require rotation. Ensure the identity retains RBAC access to:

- Target subscriptions (Reader + Policy Insights Data Writer).
- The Log Analytics workspace (Log Analytics Reader).
- The artifact Storage account (Storage Blob Data Contributor).

## Scheduling runbooks

To (re)create the daily schedule after deployment:

```pwsh
pwsh ./scripts/deploy.ps1 -SubscriptionId <subscription-guid> -WithSchedule
```

The publisher creates or updates a schedule named `APEA-Daily` and links it to `Start`.

## Monitoring and troubleshooting

- **Automation jobs** – Review the job history for `Start` and `KqlCollect`. Non-zero exit codes indicate dataset mismatches or connectivity issues.
- **Log Analytics** – Use the workspace referenced by `LOG_ANALYTICS_WORKSPACE_RESOURCE_ID` to investigate query executions and Automation diagnostics.
- **Storage** – Artifact containers live in the Storage account referenced by `ARTIFACT_STORAGE_ACCOUNT_NAME`. Enable Azure Storage insights or alerts as required.
- **Health checks** – Run `pwsh ./scripts/healthcheck.ps1` periodically to confirm tooling, authentication, and outbound network connectivity.

## Destroying the environment

To remove all Terraform-managed resources:

```pwsh
pwsh ./scripts/deploy.ps1 -SubscriptionId <subscription-guid> -Destroy
```

The script runs `terraform destroy -auto-approve`. Automation variables and historical job logs remain in Azure Automation so you can export them before deleting the account (if desired).

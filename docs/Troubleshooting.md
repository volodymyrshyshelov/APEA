# Troubleshooting Guide

This guide captures common issues encountered when deploying or operating Azure Policy Exemptions Auditor (APEA).

## 1. Authentication failures

### `scripts/deploy.ps1` reports `az login` errors
- **Symptom:** Authentication stops with CLI errors or device-code prompts.
- **Resolution:**
  - Ensure the environment has outbound access to Azure Active Directory.
  - On Azure VMs or Hybrid Workers confirm the instance metadata service (IMDS) is reachable (`curl http://169.254.169.254/metadata/instance?api-version=2021-02-01 -H Metadata:true`).
  - When MFA is required, rerun the deployment with `-ForceInteractive` to trigger device-code login.

### Terraform fails with `AuthorizationFailed`
- **Symptom:** Terraform cannot assign roles or create resources.
- **Resolution:** Run the deployment with an identity that has `Owner` or `User Access Administrator` at the subscription scope.

## 2. Terraform issues

### `Error reading Storage Account` or similar data source failures
- **Symptom:** Terraform cannot find an expected resource.
- **Resolution:** Delete any stale `terraform.auto.tfvars`, rerun the deployment, and allow the script to regenerate the file.

### `A resource with the ID already exists`
- **Symptom:** Terraform attempts to create a resource that already exists but lacks the `ap.project = "APEA"` tag.
- **Resolution:** Tag the existing resource appropriately or remove it so Terraform can recreate it.

## 3. Runbook execution problems

### `Start` runbook fails
- **Symptom:** Job output shows missing Automation variables or authentication errors.
- **Resolution:** Rerun the deployment to reseed variables. Confirm the Automation Account still has the user-assigned managed identity attached.

### `KqlCollect` reports 401/403 or exits with code 1
- **Symptom:** Log Analytics query calls fail or the result sets differ unexpectedly.
- **Resolution:**
  - Ensure the managed identity has `Log Analytics Reader` access on the workspace.
  - Verify `LOG_ANALYTICS_WORKSPACE_RESOURCE_ID` matches the workspace in use.
  - Review the JSON payload returned by the runbook for row counts and summary details.

## 4. Network connectivity

- Run `pwsh ./scripts/healthcheck.ps1` to test connectivity to IMDS and `https://api.loganalytics.io`.
- For private endpoint scenarios ensure DNS resolves `privatelink.azure-automation.net` and `privatelink.blob.core.windows.net` inside your virtual networks.

## 5. Destroy and cleanup

- Execute `pwsh ./scripts/deploy.ps1 -SubscriptionId <guid> -Destroy` to remove Terraform-managed resources.
- Automation variables and job history remain for auditing; delete the Automation Account manually if the subscription will not reuse it.

## 6. Getting help

- Review [docs/Operations.md](Operations.md) for operational procedures.
- Capture terminal output (especially from `deploy.ps1` and `healthcheck.ps1`) plus Automation job logs when opening support requests.

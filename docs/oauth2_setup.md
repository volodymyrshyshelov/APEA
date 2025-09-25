# OAuth 2.0 setup for Azure DevOps commits

Azure DevOps supports Azure AD OAuth 2.0 authorization for service principals and managed identities when an organization grants explicit access. The Automation runbook uses a refresh token stored as an encrypted Automation variable to obtain access tokens on demand.

## Prerequisites

* Azure DevOps organization URL (e.g., `https://dev.azure.com/contoso`).
* Azure DevOps project, repository, branch, and path that will receive CSV files.
* Microsoft Entra tenant administrator rights to register applications.
* Permissions in Azure DevOps to approve OAuth applications with `Code (Read & Write)` scope.

## Steps

1. **Register an app** – In Microsoft Entra ID, create an application registration for "Azure Policy Exemptions Auditor" and record the `Application (client) ID` and `Directory (tenant) ID`.
2. **Expose API permissions** – No additional API permissions are required for Azure DevOps; the app will request delegated scopes during authorization.
3. **Authorize in Azure DevOps** – Navigate to `https://app.vsaex.visualstudio.com/app/register?appName=APEA&replyUri=https://login.microsoftonline.com/common/oauth2/nativeclient&scopes=vso.code_write%20offline_access` and sign in with an Azure DevOps user that has permission to grant the app access.
4. **Capture the authorization code** – After consent, the browser redirects to a page containing the authorization code. Copy the code.
5. **Bootstrap refresh token** – Run `scripts/bootstrap_oauth_refresh.ps1` and provide:
   * Azure subscription, resource group, and Automation account names.
   * Tenant ID and client ID of the Entra app.
   * Scope string (`499b84ac-1321-427f-aa17-267ca6975798/.default` for Azure DevOps).
   * The authorization code from step 4 when prompted.
6. **Verify Automation variables** – The script stores the following encrypted variables:
   * `ADO_TENANT_ID`
   * `ADO_CLIENT_ID`
   * `ADO_REFRESH_TOKEN`
   * `ADO_SCOPE`
   * `ADO_ORG_URL`
   * `ADO_PROJECT`
   * `ADO_REPO`
   * `ADO_BRANCH`
   * `ADO_PATH_PREFIX`

## Token flow at runtime

1. Runbook reads the refresh token and metadata variables.
2. `PublishAdo.psm1` executes the OAuth 2.0 token endpoint call:
   ```text
   POST https://login.microsoftonline.com/<tenantId>/oauth2/v2.0/token
   client_id=<clientId>
   grant_type=refresh_token
   refresh_token=<refreshToken>
   scope=<scope>
   ```
3. Azure AD returns an access token valid for Azure DevOps APIs.
4. The runbook sends an authenticated POST to `https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repoId}/pushes?api-version=7.1-preview` to create a commit containing the CSV file.
5. On 401 responses, the module refreshes the token once more before failing the job.

## Operational tips

* Refresh tokens may expire if unused for extended periods. Re-run the bootstrap script to generate a new refresh token when necessary.
* Rotate the refresh token during quarterly security reviews.
* Use Automation account access control to restrict who can view or modify encrypted variables.
* Audit Azure DevOps commits for unexpected changes; they should originate from the service principal configured here.


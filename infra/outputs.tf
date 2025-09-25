output "automation_account_id" {
  description = "Resource ID of the Automation Account managed by this deployment."
  value       = local.automation_account_id
}

output "automation_account_name" {
  description = "Name of the Automation Account."
  value       = local.automation_account_name_effect
}

output "automation_account_resource_group" {
  description = "Resource group containing the Automation Account."
  value       = local.automation_account_rg_effect
}

output "storage_account_id" {
  description = "Resource ID of the storage account used for automation artifacts."
  value       = local.storage_account_id
}

output "storage_account_name" {
  description = "Name of the storage account used for automation artifacts."
  value       = local.storage_account_name_effective
}
output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace associated with the deployment."
  value       = local.log_analytics_workspace_id
}
output "hybrid_worker_group_name" {
  value = length(azurerm_automation_hybrid_runbook_worker_group.this) > 0 ? azurerm_automation_hybrid_runbook_worker_group.this[0].name : "apea-hybrid-worker-group"
}
# Правильный output для User Assigned Identity
output "user_assigned_identity_id" {
  description = "The resource ID of the User Assigned Identity"
  value = (
    var.use_existing_automation_account
    ? var.user_assigned_identity_resource_id
    : try(module.automation_account[0].user_assigned_identity_id, "")
  )
}

# Убедитесь, что storage_account_resource_group возвращает ТОЛЬКО имя группы ресурсов
output "storage_account_resource_group" {
  description = "The name of the resource group containing the storage account"
  value = (
    var.use_existing_storage_account
    ? var.existing_storage_account_rg
    : try(module.storage_account[0].resource_group_name, var.resource_group_name)
  )
}

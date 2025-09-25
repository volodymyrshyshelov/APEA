variable "subscription_id" {
  description = "Azure subscription to deploy into"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the Resource Group"
  type        = string
}

variable "create_resource_group" {
  description = "Create RG if true, otherwise use existing"
  type        = bool
  default     = true
}

variable "automation_account_name" {
  description = "Automation Account name (for new AA)"
  type        = string
}

variable "use_existing_automation_account" {
  description = "Use existing Automation Account"
  type        = bool
  default     = false
}

variable "existing_automation_account_name" {
  description = "Existing Automation Account name"
  type        = string
  default     = null
}

variable "existing_automation_account_rg" {
  description = "Resource group of existing Automation Account"
  type        = string
  default     = null
}
variable "existing_storage_account_name" {
  description = "Existing Storage Account name"
  type        = string
  default     = null
}

variable "existing_storage_account_rg" {
  description = "Existing Storage Account resource group"
  type        = string
  default     = null
}

variable "user_assigned_identity_resource_id" {
  description = "Optional UAMI resource ID to attach to Automation Account"
  type        = string
  default     = null
}

variable "log_analytics_workspace_resource_id" {
  description = "Existing Log Analytics workspace resource ID"
  type        = string
  default     = null
}

variable "log_analytics_workspace_name" {
  description = "Name for new workspace (when creating)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags to merge"
  type        = map(string)
  default     = {}
}

# По умолчанию AVM-модуль для Storage выключен из-за несовместимости в провайдере
variable "use_avm_storage_module" {
  description = "Prefer AVM storage module when creating SA"
  type        = bool
  default     = false
}

# Для fallback-ресурса azurerm_storage_account
variable "storage_shared_access_key_enabled" {
  description = "Enable shared key auth on storage (may be denied by policy). Set to false to force AAD-only."
  type        = bool
  default     = false
}

variable "storage_network_rules" {
  description = "Network rules for Storage Account (fallback resource)"
  type = object({
    default_action = string
    bypass         = set(string)
  })
  default = {
    default_action = "Deny"
    bypass         = []
  }
}
variable "use_existing_log_analytics" {
  description = "Use an existing Log Analytics workspace"
  type        = bool
  default     = false
}
variable "storage_container_name" {
  description = "Blob container name (used by bootstrap scripts)"
  type        = string
  default     = "reports"
}

variable "storage_folder_prefix" {
  description = "Folder prefix inside the blob container (used by bootstrap scripts)"
  type        = string
  default     = "policy-compliance"
}
variable "storage_account_name" {
  description = "Name of the Storage Account to create/use (Azure rules: 3-24 chars, lowercase letters and digits only)"
  type        = string
  nullable    = true
  default     = null
}

variable "use_existing_storage_account" {
  description = "If true, reuses an existing Storage Account with the exact provided name"
  type        = bool
  default     = false
}
variable "hybrid_worker_group_name" {
  description = "Name of the Hybrid Runbook Worker Group."
  type        = string
  default     = "apea-hybrid-worker-group"
}
variable "user_assigned_identity_id" {
  type        = string
  description = "Resource ID of the User Assigned Managed Identity for Automation Account"
  default     = ""
}


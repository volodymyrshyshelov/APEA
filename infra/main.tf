############################################
# RG (optional create)
############################################
resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  effective_resource_group_name = var.create_resource_group ? azurerm_resource_group.this[0].name : var.resource_group_name
  effective_location            = var.location
}

############################################
# STORAGE: Option 1 — AVM module
############################################
module "storage_account" {
  count               = var.use_existing_storage_account || !var.use_avm_storage_module ? 0 : 1
  source              = "Azure/avm-res-storage-storageaccount/azurerm"
  version             = "0.6.0"

  name                = var.storage_account_name
  location            = local.effective_location
  resource_group_name = local.effective_resource_group_name
  tags                = var.tags

  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = var.storage_shared_access_key_enabled

  network_rules = {
    default_action = var.storage_network_rules.default_action
    bypass         = var.storage_network_rules.bypass
  }
}

# Data source for existing SA
data "azurerm_storage_account" "existing" {
  count               = var.use_existing_storage_account ? 1 : 0
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
}

# Fallback resource — if not using existing and not using AVM
resource "azurerm_storage_account" "fallback" {
  count               = var.use_existing_storage_account || var.use_avm_storage_module ? 0 : 1

  name                = var.storage_account_name
  location            = local.effective_location
  resource_group_name = local.effective_resource_group_name
  tags                = var.tags

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  shared_access_key_enabled     = var.storage_shared_access_key_enabled
  public_network_access_enabled = false
  min_tls_version               = "TLS1_2"

  network_rules {
    default_action = var.storage_network_rules.default_action
    bypass         = var.storage_network_rules.bypass
  }

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # Storage Account ID — from existing data source, or AVM module, or fallback resource
  storage_account_id = coalesce(
    try(data.azurerm_storage_account.existing[0].id, null),
    try(module.storage_account[0].resource_id, null),
    try(azurerm_storage_account.fallback[0].id, null),
    null
  )

  # Effective Storage Account name
  storage_account_name_effective = coalesce(
    try(data.azurerm_storage_account.existing[0].name, null),
    try(module.storage_account[0].name, null),
    try(azurerm_storage_account.fallback[0].name, null),
    var.storage_account_name
  )

  # Effective RG for storage — parse from resource_id if possible
  # /subscriptions/<sub>/resourceGroups/<RG>/providers/...
  storage_account_rg_effective = try(
    element(split("/", local.storage_account_id), 4),
    var.resource_group_name,
    local.effective_resource_group_name
  )
}

############################################
# UAMI (optional)
############################################
resource "azurerm_user_assigned_identity" "this" {
  count               = (var.user_assigned_identity_resource_id == null || var.user_assigned_identity_resource_id == "") && !var.use_existing_automation_account ? 1 : 0
  name                = "${var.automation_account_name}-uami"
  location            = local.effective_location
  resource_group_name = local.effective_resource_group_name
  tags                = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  created_identity_id     = length(azurerm_user_assigned_identity.this) == 0 ? null : azurerm_user_assigned_identity.this[0].id
  effective_identity_id   = (var.user_assigned_identity_resource_id != null && var.user_assigned_identity_resource_id != "") ? var.user_assigned_identity_resource_id : local.created_identity_id
  automation_identity_ids = local.effective_identity_id == null ? [] : [local.effective_identity_id]
}

############################################
# Log Analytics (optional)
############################################
resource "azurerm_log_analytics_workspace" "this" {
  count               = (var.log_analytics_workspace_resource_id == null || var.log_analytics_workspace_resource_id == "") && !var.use_existing_log_analytics ? 1 : 0
  name                = coalesce(var.log_analytics_workspace_name, "${var.automation_account_name}-law")
  location            = local.effective_location
  resource_group_name = local.effective_resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Existing LAW
data "azurerm_log_analytics_workspace" "existing" {
  count               = var.use_existing_log_analytics ? 1 : 0
  name                = var.log_analytics_workspace_name
  resource_group_name = local.effective_resource_group_name
}

locals {
  _law_id_from_var = (var.log_analytics_workspace_resource_id != null && var.log_analytics_workspace_resource_id != "") ? var.log_analytics_workspace_resource_id : null

  log_analytics_workspace_id = coalesce(
    local._law_id_from_var,
    try(data.azurerm_log_analytics_workspace.existing[0].id, null),
    try(azurerm_log_analytics_workspace.this[0].id, null)
  )
}

############################################
# Automation Account (AVM)
############################################
module "automation_account" {
  count               = var.use_existing_automation_account ? 0 : 1
  source              = "Azure/avm-res-automation-automationaccount/azurerm"
  version             = "0.2.0"

  name                = var.automation_account_name
  location            = local.effective_location
  resource_group_name = local.effective_resource_group_name

  sku                 = "Basic"
  tags                = var.tags

  public_network_access_enabled = false

  managed_identities = {
    system_assigned            = length(local.automation_identity_ids) == 0
    user_assigned_resource_ids = local.automation_identity_ids
  }
}

############################################
# Automation Account (existing)
############################################
data "azurerm_automation_account" "existing" {
  count = (
    var.use_existing_automation_account &&
    try(trimspace(var.existing_automation_account_name) != "", false) &&
    try(trimspace(var.existing_automation_account_rg)   != "", false)
  ) ? 1 : 0

  name                = var.existing_automation_account_name
  resource_group_name = var.existing_automation_account_rg
}

############################################
# Locals for AA
############################################
locals {
  automation_account_id = try(
    coalesce(
      try(data.azurerm_automation_account.existing[0].id, null),
      try(module.automation_account[0].resource_id, null)
    ),
    null
  )

  automation_account_name_effect = (
    var.use_existing_automation_account
      ? var.existing_automation_account_name
      : var.automation_account_name
  )

  automation_account_rg_effect = (
    var.use_existing_automation_account
      ? var.existing_automation_account_rg
      : local.effective_resource_group_name
  )
}

############################################
# STORAGE CONTAINER — create only if account is not existing
############################################
resource "azurerm_storage_container" "reports" {
  count                 = var.use_existing_storage_account ? 0 : 1
  name                  = var.storage_container_name
  storage_account_id    = local.storage_account_id
  container_access_type = "private"
}

############################################
# Hybrid Worker Group — only when AA is new
############################################
resource "azurerm_automation_hybrid_runbook_worker_group" "this" {
  count                   = var.use_existing_automation_account ? 0 : 1
  name                    = var.hybrid_worker_group_name
  resource_group_name     = local.automation_account_rg_effect
  automation_account_name = local.automation_account_name_effect

  # Ensure AA is created before HWG when AA is new
  depends_on = [module.automation_account]
}

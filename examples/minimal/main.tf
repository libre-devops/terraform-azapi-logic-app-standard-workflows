locals {
  location   = "uksouth"
  rg_name    = "rg-${var.short}-${var.loc}-${terraform.workspace}-001"
  logic_name = "logic-${var.short}-${var.loc}-${terraform.workspace}-01"
  sa_name    = "st${var.short}${var.loc}${terraform.workspace}001"
}

module "tags" {
  source  = "libre-devops/tags/azurerm"
  version = "~> 4.0"

  cost_centre     = "1888/67"
  owner           = "platform@example.com"
  deployed_branch = var.deployed_branch
  deployed_repo   = var.deployed_repo
}

module "rg" {
  source  = "libre-devops/rg/azurerm"
  version = "~> 4.0"

  resource_groups = [{ name = local.rg_name, location = local.location, tags = module.tags.tags }]
}

# The HOST. This module deliberately does not own it: plan, storage and site are the azurerm
# module's job, and duplicating a mature host module to make one call look tidier would be a
# worse trade than composing.
module "logic_app_standard" {
  source  = "libre-devops/logic-app-standard/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  logic_apps = {
    (local.logic_name) = {}
  }
}

# Somewhere to stage the deployment package. ARM carries no bytes, so the package has to sit
# somewhere the platform can GET it.
#
# Deliberately NOT the Logic App's own runtime storage account: that account holds the app's
# content share, state and run history, and mixing deployment artefacts into it makes the blast
# radius of a storage mistake much larger than it needs to be.
resource "azurerm_storage_account" "packages" {
  name                            = local.sa_name
  resource_group_name             = provider::azurerm::parse_resource_id(module.rg.ids[local.rg_name]).resource_group_name
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true # the package SAS is minted from the account key
  tags                            = module.tags.tags

  # Deny by default, with the trusted-services bypass so the platform can fetch the package.
  #
  # If a deploy ever fails with the platform unable to GET the packageUri, THIS is the first thing
  # to check. The fallbacks, in order of preference: a private endpoint on the blob service with
  # VNet integration on the app, or an ip_rules allowlist of the app's outbound IPs. Opening the
  # account to the internet is not one of them.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "packages" {
  name                  = "deployments"
  storage_account_id    = azurerm_storage_account.packages.id
  container_access_type = "private"
}

# The CONTENT. One workflow, rendered from a portal-shaped template with one scalar token, shipped
# as a package and deployed through the ARM ZipDeploy extension.
module "logic_app_workflows" {
  source = "../../"

  logic_app_id = module.logic_app_standard.logic_app_ids[local.logic_name]

  package_storage = {
    storage_account_id = azurerm_storage_account.packages.id
    container_name     = azurerm_storage_container.packages.name
  }

  workflows = {
    "daily-greeting" = {
      definition = templatefile("${path.module}/templates/daily-greeting.json.tftpl", {
        greeting = "hello from ${local.logic_name}"
      })
    }
  }
}

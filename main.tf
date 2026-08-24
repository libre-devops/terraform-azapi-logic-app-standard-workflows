# Logic App Standard workflow content, deployed as one package through azapi.
#
# The design fact this module exists to encode: ON STANDARD, A WORKFLOW IS NOT AN ARM RESOURCE.
# There is no Microsoft.Web/sites/workflows type. A workflow is a file, <name>/workflow.json, in a
# package the Functions host loads, alongside connections.json and host.json. So the Consumption
# module's shape (one PUT per workflow, per-workflow lifecycle, deploy_tier ordering) has no
# equivalent here and is deliberately not imitated.
#
# What IS an ARM resource is the deployment itself: Microsoft.Web/sites/extensions named ZipDeploy,
# carrying a packageUri the platform fetches. That is the whole reason this module is azapi rather
# than a shell script:
#   - it is a control-plane call, so it needs NO basic-auth publishing profile. The azurerm
#     zip_deploy_file path does, which is why the Libre DevOps function app modules disable it and
#     tell you to push from outside Terraform.
#   - it plans, and the package hash is in the plan, so a content change is visible before apply.
#
# What it still cannot be is a per-workflow lifecycle. Removing a workflow means shipping a package
# without it. That is the platform's model, not a limitation of this module, and pretending
# otherwise would be the dishonest option.

locals {
  # The scaffolded Standard host.json. Overridable, but this is what a `func init` Standard project
  # is born with and what the portal expects to find.
  default_host_json = jsonencode({
    version = "2.0"
    extensionBundle = {
      id      = "Microsoft.Azure.Functions.ExtensionBundle.Workflows"
      version = "[1.*, 2.0.0)"
    }
  })

  # Each workflow becomes <name>/workflow.json. Two input shapes are accepted because both are
  # what Azure hands you: a Standard workflow.json already wrapped as {"definition": ..., "kind":
  # ...}, or a bare definition. A workflow definition has no top-level "definition" key of its own,
  # so the unwrap is unambiguous, exactly as in the Consumption module.
  #
  # The definition itself is never reshaped. That is what keeps a committed template diffable
  # against a fresh portal export.
  decoded = { for k, w in var.workflows : k => jsondecode(w.definition) }

  workflow_files = {
    for k, w in var.workflows : "${k}/workflow.json" => jsonencode({
      definition = try(local.decoded[k].definition, local.decoded[k])
      kind       = coalesce(w.kind, try(local.decoded[k].kind, null), "Stateful")
    })
  }

  # connections.json. The authentication block is written in the AZURE format, never the Visual
  # Studio Code format: locally a managed API connection authenticates with a Raw scheme and an
  # appsetting key, and releasing that shape unchanged is the classic Standard deployment failure.
  # ManagedServiceIdentity is what Azure expects, and what the app's own identity uses.
  managed_api_connections = {
    for k, c in var.managed_api_connections : k => {
      api                  = { id = c.managed_api_id }
      connection           = { id = c.connection_id }
      connectionRuntimeUrl = c.connection_runtime_url
      authentication       = c.managed_identity_auth ? { type = "ManagedServiceIdentity" } : { type = "Raw", scheme = "Key", parameter = "@appsetting('${k}-connectionKey')" }
    }
  }

  connections_json = jsonencode(merge(
    length(local.managed_api_connections) > 0 ? { managedApiConnections = local.managed_api_connections } : {},
    length(var.service_provider_connections) > 0 ? { serviceProviderConnections = var.service_provider_connections } : {},
  ))

  package_files = merge(
    local.workflow_files,
    {
      "connections.json" = local.connections_json
      "host.json"        = coalesce(var.host_json, local.default_host_json)
    },
    var.extra_files,
  )

  build_package = var.package_uri == null
  output_path   = coalesce(var.package_output_path, "${path.root}/.terraform/${var.package_blob_prefix}-package.zip")

  storage = local.build_package ? provider::azurerm::parse_resource_id(var.package_storage.storage_account_id) : null
}

locals {
  # The URI the platform fetches. Either the blob just uploaded, with its read SAS, or whatever the
  # caller staged themselves.
  package_uri = local.build_package ? "${azurerm_storage_blob.package[0].url}${data.azurerm_storage_account_blob_container_sas.package[0].sas}" : var.package_uri
}

# The package, built in memory from rendered content. Nothing is read from disk, so a plan in CI
# needs no working tree beyond the configuration itself.
data "archive_file" "package" {
  count = local.build_package ? 1 : 0

  type        = "zip"
  output_path = local.output_path

  dynamic "source" {
    for_each = local.package_files
    content {
      content  = source.value
      filename = source.key
    }
  }
}

# Pins the SAS window to the package VERSION rather than to wall clock. A timestamp() in the SAS
# start would otherwise re-plan on every run for ever, which is the usual way this pattern rots.
resource "time_static" "sas" {
  count = local.build_package ? 1 : 0

  triggers = {
    package_sha256 = data.archive_file.package[0].output_sha256
  }
}

data "azurerm_storage_account" "package" {
  count = local.build_package ? 1 : 0

  name                = local.storage.resource_name
  resource_group_name = local.storage.resource_group_name
}

# A read-only, short-lived, container-scoped SAS. It has one job: outlive the apply so the platform
# can GET the package once. Read only, https only, no list.
data "azurerm_storage_account_blob_container_sas" "package" {
  count = local.build_package ? 1 : 0

  connection_string = data.azurerm_storage_account.package[0].primary_connection_string
  container_name    = var.package_storage.container_name
  https_only        = true

  start  = time_static.sas[0].rfc3339
  expiry = timeadd(time_static.sas[0].rfc3339, "${var.package_storage.sas_expiry_hours}h")

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = false
  }
}

# The blob name carries the content hash, so a content change is a NEW blob and therefore a new
# packageUri, which is what re-triggers the deployment below. Overwriting one blob in place would
# leave packageUri unchanged and the deploy would not fire.
resource "azurerm_storage_blob" "package" {
  count = local.build_package ? 1 : 0

  name = "${var.package_blob_prefix}-${substr(data.archive_file.package[0].output_sha256, 0, 16)}.zip"
  # storage_container_id rather than the account/container name pair: the pair is deprecated and
  # goes away in azurerm v5.
  storage_container_id = "${var.package_storage.storage_account_id}/blobServices/default/containers/${var.package_storage.container_name}"
  type                 = "Block"
  source               = data.archive_file.package[0].output_path
  content_md5          = data.archive_file.package[0].output_md5
  content_type         = "application/zip"
}

# The deployment. ZipDeploy is an ARM control-plane call: the platform fetches the package itself,
# so nothing here needs the site's publishing credentials and basic auth can stay disabled.
resource "azapi_resource" "deploy" {
  type      = "Microsoft.Web/sites/extensions@${var.api_version}"
  name      = "ZipDeploy"
  parent_id = var.logic_app_id

  # The extension is an action dressed as a resource: its GET does not echo a packageUri back, so
  # schema validation and response export are both off. What proves a deploy happened is the blob
  # hash in the plan and the app's own content, not this resource's state.
  schema_validation_enabled = false
  response_export_values    = []

  body = {
    properties = {
      packageUri = local.package_uri
    }
  }

  lifecycle {
    replace_triggered_by = [terraform_data.package_version]
  }
}

# Carries the package identity into a replace trigger, so a content change re-runs the deployment
# rather than being a no-op update on an action-shaped resource.
resource "terraform_data" "package_version" {
  input = local.package_uri
}

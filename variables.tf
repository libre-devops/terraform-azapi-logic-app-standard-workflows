variable "logic_app_id" {
  description = "Resource id of the EXISTING Logic App Standard site the workflows deploy into (Microsoft.Web/sites). This module owns content, never the host: the plan, storage account and site come from libre-devops/logic-app-standard/azurerm or your own configuration."
  type        = string

  validation {
    condition     = can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Web/sites/[^/]+$", var.logic_app_id))
    error_message = "logic_app_id must be a Microsoft.Web/sites resource id."
  }
}

variable "workflows" {
  description = <<-EOT
    The workflows to deploy, keyed by workflow name. The key becomes the folder name in the
    package, so it is the name shown in the portal and in every run history entry.

      definition  The workflow.json content, as a STRING, normally rendered with templatefile.
                  Two shapes are accepted, because both are what Azure gives you:
                    a Standard workflow.json   {"definition": {...}, "kind": "Stateful"}
                    a bare definition          {"$schema": ..., "triggers": {...}, ...}
                  A bare definition is wrapped with `kind` below. An already-wrapped shape keeps
                  its own kind unless `kind` is set here, which wins.

      kind        Stateful (default) or Stateless. Stateless has a 5 minute execution ceiling and
                  no run history, which is the wrong trade for almost every playbook: the Libre
                  DevOps standard says Stateful unless you have MEASURED that 5 minutes is always
                  enough.

    There is no deploy_tier here, unlike the Consumption module. Every workflow in a Standard app
    ships in one package and the host loads them together, so there is no ordering to express.
  EOT

  type = map(object({
    definition = string
    kind       = optional(string)
  }))

  validation {
    condition     = length(var.workflows) > 0
    error_message = "workflows must not be empty: deploying a package with no workflows would blank the app's content."
  }

  validation {
    condition     = alltrue([for k, w in var.workflows : can(jsondecode(w.definition))])
    error_message = "every workflow definition must be valid JSON. When rendering a .json.tftpl, remember Terraform's template escapes: a literal dollar-brace must be written doubled, and so must a literal percent-brace."
  }

  validation {
    condition     = alltrue([for k, w in var.workflows : contains(["Stateful", "Stateless"], coalesce(w.kind, "Stateful"))])
    error_message = "workflow kind must be Stateful or Stateless."
  }

  validation {
    condition     = alltrue([for k, w in var.workflows : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$", k))])
    error_message = "a workflow name becomes a folder in the package: letters, digits, dot, dash or underscore, starting with a letter or digit, at most 63 characters."
  }

  validation {
    condition = alltrue([
      for k, w in var.workflows :
      length(try(jsondecode(w.definition).definition.triggers, jsondecode(w.definition).triggers, {})) > 0
    ])
    error_message = "every workflow needs at least one trigger: a definition with none deploys cleanly and can never run."
  }
}

variable "managed_api_connections" {
  description = <<-EOT
    Managed API connections written into connections.json, keyed by the name the workflows
    reference. Standard is not Consumption here, and the differences bite:

      - Standard uses V2 connections, which REQUIRE an access policy granting the app's identity
        access. Consumption V1 connections reject access policies outright. This module does not
        create those policies: they belong with the connection, not with the content.
      - The authentication block must be the AZURE format, not the Visual Studio Code format.
        managed_identity_auth writes {"type": "ManagedServiceIdentity"}, which is what Azure
        expects; the local VS Code shape (Raw plus an appsetting key) must be converted before
        release, and forgetting is the classic Standard deployment failure.
  EOT

  type = map(object({
    connection_id          = string
    managed_api_id         = string
    connection_runtime_url = string
    managed_identity_auth  = optional(bool, true)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, c in var.managed_api_connections : can(regex("^https://", c.connection_runtime_url))])
    error_message = "connection_runtime_url must be the https runtime URL from the connection resource (properties.connectionRuntimeUrl)."
  }
}

variable "service_provider_connections" {
  description = "Service provider (built-in) connections written into connections.json, keyed by name, each an object passed through as authored. These are the in-process connectors (Azure Blob, Service Bus, SQL and friends), which use no managed connector infrastructure and therefore carry no access policy and no managed API id."
  type        = any
  default     = {}
}

variable "host_json" {
  description = "host.json content, as a string. Defaults to the extension bundle host.json a Standard project is scaffolded with. Override to pin a different bundle range or to set runtime options."
  type        = string
  default     = null

  validation {
    condition     = var.host_json == null || can(jsondecode(var.host_json))
    error_message = "host_json must be valid JSON."
  }
}

variable "extra_files" {
  description = "Extra files placed in the package, keyed by path relative to the package root, value is the file content. Use for artifacts a workflow references, such as a Liquid map or an XSLT. Keys may contain forward slashes to nest."
  type        = map(string)
  default     = {}
}

variable "package_storage" {
  description = <<-EOT
    Where the package is staged so the platform can fetch it. ARM carries no bytes, so the zip has
    to live at a URI the Logic App can GET.

      storage_account_id    Resource id of the account holding the container.
      container_name        An EXISTING private container. The read SAS below is the access.
      sas_expiry_hours      Lifetime of the read SAS minted for the deploy. Short on purpose: it
                            only has to outlive the apply.

    Leave null and set package_uri instead if you stage the package yourself.
  EOT

  type = object({
    storage_account_id = string
    container_name     = string
    sas_expiry_hours   = optional(number, 2)
  })
  default = null

  validation {
    condition     = var.package_storage == null || try(var.package_storage.sas_expiry_hours, 2) >= 1
    error_message = "sas_expiry_hours must be at least 1."
  }

  validation {
    condition     = var.package_storage == null || can(regex("(?i)/providers/Microsoft\\.Storage/storageAccounts/[^/]+$", var.package_storage.storage_account_id))
    error_message = "storage_account_id must be a Microsoft.Storage/storageAccounts resource id."
  }
}

variable "package_uri" {
  description = "A URI the platform can GET the package from, when you stage it yourself. Mutually exclusive with package_storage: the module then deploys this URI and builds nothing."
  type        = string
  default     = null

  validation {
    condition     = var.package_uri == null || can(regex("^https://", var.package_uri))
    error_message = "package_uri must be an https URI the Logic App can reach."
  }
}

variable "api_version" {
  description = "API version for the Microsoft.Web/sites/extensions deployment resource."
  type        = string
  default     = "2024-04-01"

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}(-preview)?$", var.api_version))
    error_message = "api_version must look like 2024-04-01."
  }
}

variable "package_blob_prefix" {
  description = "Prefix for the package blob name inside the container. The content hash is always appended, so a content change is a new blob and the deploy is re-triggered."
  type        = string
  default     = "logic-app-standard"
}

variable "package_output_path" {
  description = "Where the built zip is written locally before upload. Defaults to the root module's .terraform directory, which is already gitignored and already ephemeral."
  type        = string
  default     = null
}

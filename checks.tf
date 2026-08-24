# Checks warn; they never block. Everything the PLATFORM rejects is a variable validation instead,
# so it fails the plan. These are the things that deploy cleanly and bite later.

check "connections_are_referenced" {
  assert {
    condition = alltrue([
      for name in keys(var.managed_api_connections) :
      anytrue([for k, w in var.workflows : strcontains(w.definition, name)])
    ])
    error_message = "a managed API connection is declared in connections.json that no workflow definition mentions. It will be deployed, and an unused V2 connection still needs its access policy, so this is usually a leftover from a workflow that was removed."
  }
}

check "connections_have_a_home" {
  assert {
    condition = length(var.managed_api_connections) == 0 || alltrue([
      for k, c in var.managed_api_connections : c.managed_identity_auth
    ])
    error_message = "a managed API connection is set to key authentication rather than managed identity. That works, but it puts a connection key in an app setting: prefer managed_identity_auth = true and an access policy on the connection."
  }
}

check "stateless_workflows_are_deliberate" {
  assert {
    condition = alltrue([
      for k, w in var.workflows : coalesce(w.kind, try(jsondecode(w.definition).kind, null), "Stateful") == "Stateful"
    ])
    error_message = "a workflow is Stateless. Stateless has a 5 minute execution ceiling and NO run history, which makes an incident unreconstructable. The Libre DevOps standard says Stateful unless you have measured that 5 minutes is always enough."
  }
}

check "sas_window_is_short" {
  assert {
    condition     = var.package_storage == null || try(var.package_storage.sas_expiry_hours, 2) <= 24
    error_message = "the package SAS lives longer than a day. It only has to outlive the apply; a long-lived read SAS on a container is a standing credential in your state file."
  }
}

check "package_is_not_enormous" {
  assert {
    condition     = !local.build_package || data.archive_file.package[0].output_size < 100 * 1024 * 1024
    error_message = "the deployment package is over 100 MB. Standard packages are workflow JSON and small artifacts; something large has been swept in through extra_files."
  }
}

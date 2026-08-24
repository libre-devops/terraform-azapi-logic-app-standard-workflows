output "package_sha256" {
  description = "The deployed package hash: the promotion and rollback record."
  value       = module.logic_app_workflows.package_sha256
}

output "workflow_names" {
  description = "Workflows deployed into the app."
  value       = module.logic_app_workflows.workflow_names
}

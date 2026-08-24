output "package_uri" {
  description = "The URI the platform was told to fetch the package from. Carries a short-lived read SAS when the module built the package, so treat it as sensitive."
  value       = local.package_uri
  sensitive   = true
}

output "package_sha256" {
  description = "SHA256 of the built package. This is the promotion and rollback record: it is what changed when the deployment re-ran, and the only stable identity a Standard content deploy has."
  value       = local.build_package ? data.archive_file.package[0].output_sha256 : null
}

output "package_blob_name" {
  description = "Name of the uploaded package blob, which carries the content hash. Null when package_uri was supplied."
  value       = local.build_package ? azurerm_storage_blob.package[0].name : null
}

output "package_files" {
  description = "The package contents by path, as deployed. Useful in a test to assert what was built without unzipping anything."
  value       = keys(local.package_files)
}

output "workflow_names" {
  description = "The workflow names deployed, which are the folder names in the package and the names shown in the portal."
  value       = sort(keys(var.workflows))
}

output "deployment_id" {
  description = "Resource id of the ZipDeploy extension deployment."
  value       = azapi_resource.deploy.id
}

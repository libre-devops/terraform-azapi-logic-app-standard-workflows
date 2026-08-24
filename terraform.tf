terraform {
  # 1.11 floor, matching terraform-azapi-logic-app-workflow: this module does not use write-only
  # attributes today, but the two are deployed side by side in the same roots and a split floor
  # is a support burden with no upside.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.5.0, < 3.0.0"
    }
    # The package has to reach the platform through a URI it can GET, and neither azapi nor the
    # ARM control plane can carry bytes. azurerm uploads the blob and mints the read SAS.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0.0, < 5.0.0"
    }
    # Builds the deployment zip from rendered content in memory. No files are written to disk, so
    # a plan in CI needs no working directory and nothing lands beside the configuration.
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0, < 3.0.0"
    }
    # Pins the SAS window to the package version rather than to wall clock. Without it a
    # timestamp() in the SAS start would re-plan on every run, for ever.
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11.0, < 1.0.0"
    }
  }
}

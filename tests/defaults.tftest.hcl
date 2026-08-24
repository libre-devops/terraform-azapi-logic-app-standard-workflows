# Offline gates. No Azure, no credentials, no cost: the providers are mocked and the only things
# that really run are the zip build and the pure-HCL rendering, which is where the module's
# behaviour actually lives.

mock_provider "azurerm" {
  mock_data "azurerm_storage_account" {
    defaults = {
      primary_connection_string = "DefaultEndpointsProtocol=https;AccountName=stmock;AccountKey=bW9jaw==;EndpointSuffix=core.windows.net"
    }
  }
  mock_data "azurerm_storage_account_blob_container_sas" {
    defaults = {
      sas = "?sv=mock&sig=mock"
    }
  }
}

mock_provider "azapi" {}

variables {
  logic_app_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/sites/logic-ldo-uks-prd-001"

  package_storage = {
    storage_account_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stldouksprd001"
    container_name     = "deployments"
  }

  workflows = {
    "incident-ack" = {
      definition = <<-JSON
        {
          "definition": {
            "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
            "contentVersion": "1.0.0.0",
            "triggers": { "manual": { "type": "Request", "kind": "Http" } },
            "actions": { "Compose": { "type": "Compose", "inputs": "hello", "runAfter": {} } },
            "outputs": {}
          },
          "kind": "Stateful"
        }
      JSON
    }
  }
}

run "package_is_built_from_the_workflows" {
  command = plan

  assert {
    condition     = contains(output.package_files, "incident-ack/workflow.json")
    error_message = "each workflow must become <name>/workflow.json in the package"
  }

  assert {
    condition     = contains(output.package_files, "host.json") && contains(output.package_files, "connections.json")
    error_message = "the package must carry host.json and connections.json alongside the workflows"
  }

  assert {
    condition     = output.workflow_names == tolist(["incident-ack"])
    error_message = "workflow_names must list the deployed workflows"
  }
}

run "a_bare_definition_is_wrapped" {
  command = plan

  variables {
    workflows = {
      "bare" = {
        definition = <<-JSON
          {
            "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
            "contentVersion": "1.0.0.0",
            "triggers": { "Recurrence": { "type": "Recurrence", "recurrence": { "frequency": "Day", "interval": 1 } } },
            "actions": {},
            "outputs": {}
          }
        JSON
      }
    }
  }

  assert {
    condition     = contains(output.package_files, "bare/workflow.json")
    error_message = "a bare definition must still produce a workflow.json"
  }
}

run "an_empty_workflow_map_is_rejected" {
  command = plan

  variables {
    workflows = {}
  }

  expect_failures = [var.workflows]
}

run "a_definition_without_a_trigger_is_rejected" {
  command = plan

  variables {
    workflows = {
      "no-trigger" = {
        definition = "{\"$schema\":\"x\",\"contentVersion\":\"1.0.0.0\",\"triggers\":{},\"actions\":{}}"
      }
    }
  }

  expect_failures = [var.workflows]
}

run "a_non_json_definition_is_rejected" {
  command = plan

  variables {
    workflows = {
      "broken" = { definition = "not json at all" }
    }
  }

  expect_failures = [var.workflows]
}

run "a_bad_logic_app_id_is_rejected" {
  command = plan

  variables {
    logic_app_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Logic/workflows/not-a-site"
  }

  expect_failures = [var.logic_app_id]
}

run "managed_identity_auth_is_written_in_the_azure_format" {
  command = plan

  variables {
    # The workflow must reference the connection, or the connections_are_referenced check fires,
    # which is itself the behaviour asserted by the run below this one.
    workflows = {
      "uses-sentinel" = {
        definition = <<-JSON
          {
            "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
            "contentVersion": "1.0.0.0",
            "triggers": { "manual": { "type": "Request", "kind": "Http" } },
            "actions": {
              "Add_comment": {
                "type": "ApiConnection",
                "inputs": { "host": { "connection": { "referenceName": "azuresentinel" } }, "method": "post", "path": "/Incidents/Comment" },
                "runAfter": {}
              }
            },
            "outputs": {}
          }
        JSON
      }
    }

    managed_api_connections = {
      "azuresentinel" = {
        connection_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/connections/conn-sentinel"
        managed_api_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Web/locations/uksouth/managedApis/azuresentinel"
        connection_runtime_url = "https://uksouth.common.logic-uksouth.azure-apihub.net/apim/azuresentinel/abc/"
      }
    }
  }

  assert {
    condition     = strcontains(local.connections_json, "ManagedServiceIdentity")
    error_message = "connections.json must use the Azure authentication format, not the Visual Studio Code Raw/Key shape"
  }
}

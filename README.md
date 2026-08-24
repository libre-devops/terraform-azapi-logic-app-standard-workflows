<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="300">
    </picture>
  </a>
</div>

# Terraform AzAPI Logic App Standard Workflows

Logic App **Standard** workflow content as code: workflows rendered from portal-shaped templates by
`templatefile`, packaged with `connections.json` and `host.json`, and deployed through the ARM
ZipDeploy extension, so a content change plans before it applies and needs no publishing profile.

---

## Overview

This is the Standard counterpart to
[`terraform-azapi-logic-app-workflow`](https://github.com/libre-devops/terraform-azapi-logic-app-workflow),
and it is deliberately **not** a port of it, because the platform is not the same underneath.

> **On Standard, a workflow is not an ARM resource.** There is no `Microsoft.Web/sites/workflows`
> type. A workflow is a file, `<name>/workflow.json`, inside a package the Functions host loads
> alongside `connections.json` and `host.json`.

So the Consumption module's whole shape (one PUT per workflow, per-workflow lifecycle, `deploy_tier`
ordering) has no equivalent here, and imitating it would be a lie about the platform.

What **is** an ARM resource is the deployment: `Microsoft.Web/sites/extensions` named `ZipDeploy`,
carrying a `packageUri` the platform fetches. That is why this module is azapi rather than a shell
script, and it buys two things that matter:

- **No publishing profile.** ZipDeploy through ARM is a control-plane call, so basic authentication
  can stay disabled on the site. The `azurerm` `zip_deploy_file` path needs the basic-auth
  publishing profile, which is why the Libre DevOps function app modules disable it and tell you to
  push from outside Terraform.
- **It plans.** The package hash is in the plan, so a content change is visible before apply, and
  the hash is the promotion and rollback record.

### What carries over from Consumption, and what does not

| | Consumption module | This module |
|---|---|---|
| Export you start from | portal **code view** | portal **Download app content** zip |
| Artefact | one definition | `workflow.json` per workflow, plus `connections.json` and `host.json` |
| Deployed by | one PUT to `Microsoft.Logic/workflows` | one package, one ZipDeploy extension |
| `templatefile` token contract | identical | identical |
| Ordering | `deploy_tier` | not needed: one package, loaded together |
| Lifecycle | per workflow create/update/destroy | whole-app content replace |
| Parameter values | ARM body `parameters` | app settings and `@appsetting()`, owned by the host |
| Secrets | `sensitive_body` | app settings or Key Vault references, owned by the host |
| Connections | V1, access policies **rejected** | V2, access policies **required** |

### It owns content, never the host

The plan, storage account and site come from
[`libre-devops/logic-app-standard/azurerm`](https://registry.terraform.io/modules/libre-devops/logic-app-standard/azurerm)
or your own configuration. Two reasons, both practical: the host module is mature and duplicating it
to make one call look tidier is a bad trade, and app settings have exactly one owner. A content
module that also wrote `WEBSITE_RUN_FROM_PACKAGE` would fight the host module over the same
attribute on every apply. ZipDeploy touches no app settings at all, which is the other reason to
prefer it.

## Usage

```hcl
module "logic_app_workflows" {
  source  = "libre-devops/logic-app-standard-workflows/azapi"
  version = "~> 1.0"

  logic_app_id = module.logic_app_standard.logic_app_ids["logic-ldo-uks-prd-01"]

  package_storage = {
    storage_account_id = azurerm_storage_account.packages.id
    container_name     = azurerm_storage_container.packages.name
  }

  managed_api_connections = {
    "azuresentinel" = {
      connection_id          = azapi_resource.sentinel_connection.id
      managed_api_id         = data.azurerm_managed_api.sentinel.id
      connection_runtime_url = azapi_resource.sentinel_connection.output.properties.connectionRuntimeUrl
      managed_identity_auth  = true
    }
  }

  workflows = {
    "incident-ack" = {
      definition = templatefile("${path.module}/templates/incident-ack.json.tftpl", {
        workspace_id = module.law.workspace_ids["log-ldo-uks-prd-001"]
      })
    }
  }
}
```

## Authoring: the same round trip as Consumption

1. Build it in the designer.
2. **Download app content** from the app's Overview blade, or copy one workflow's code view.
3. Paste each workflow into `templates/<name>.json.tftpl`.
4. Ctrl+F the values Terraform owns into `${tokens}`.
5. Plan.

Both shapes paste in unchanged: a Standard `workflow.json` (`{"definition": {...}, "kind": ...}`)
and a bare definition. A definition has no top-level `definition` key of its own, so the unwrap is
unambiguous, and the definition itself is never reshaped, which is what keeps a committed template
diffable against a fresh export.

Point your editor at the
[annotated WDL schema](https://github.com/libre-devops/terraform-azapi-logic-app-workflow/tree/main/schema)
while you write: it validates the `definition` block of a Standard `workflow.json` too, and unlike
the published schema it does not redline correct code.

## The connections.json trap

Locally, Visual Studio Code writes managed API connections with a `Raw` scheme and an appsetting
key. **Azure expects `ManagedServiceIdentity`.** Releasing the local shape unchanged is the classic
Standard deployment failure, so `managed_identity_auth` (default `true`) writes the Azure format for
you.

Standard uses **V2** connections, which **require** an access policy granting the app's identity
access. Consumption V1 connections reject access policies outright. This module does not create
those policies: they belong with the connection, not with the content.

## Guard rails

Anything the platform rejects fails the **plan**, as a variable validation: a definition that is not
JSON, a workflow with no trigger, an empty workflow map, a bad `logic_app_id`, an unusable workflow
name. Anything that deploys cleanly and bites later is a `check`, which warns: a connection no
workflow references, key authentication where managed identity would do, a Stateless workflow, a SAS
window longer than a day, a package over 100 MB.

## Developing

```bash
terraform init -backend=false && terraform test    # offline: mocked providers, no Azure, no cost
terraform fmt -recursive -check
tflint --recursive
trivy config --skip-dirs '**/.terraform/**' .
```

`terraform test` runs seven cases with mocked providers: the package layout, bare-definition
wrapping, the Azure authentication format in `connections.json`, and four rejection cases proving
the plan-time guards actually fire.

## Security scan exceptions

This module is scanned with [Trivy](https://github.com/aquasecurity/trivy); HIGH and CRITICAL
findings fail the build. Any waiver is a deliberate, reviewed decision, never a way to quiet a
finding that should be fixed.

| Trivy ID | Resource | Finding | Justification |
|----------|----------|---------|---------------|
| _None_   |          |         |               |

## Status

> **The offline gates are green and the live path is UNPROVEN.** `terraform test` passes with
> mocked providers, `validate`, `fmt`, `tflint` and `trivy` are clean, and the package build and
> rendering are exercised. What has **not** been done is an apply against a real tenant, so the
> ZipDeploy extension behaviour on a Workflow Standard plan is asserted from Microsoft's
> documentation rather than from a run. Treat the first deployment as the proving run, and if it
> misbehaves the finding belongs in this section rather than in a silent fix.

Everything the Consumption module claims is proven live. This one does not make that claim yet, and
saying so is the point.

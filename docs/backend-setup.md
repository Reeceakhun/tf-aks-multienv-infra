# Remote State Backend Setup

Terraform state for this project lives in Azure Storage. This backend is
created **once, manually** — it is deliberately outside this repo's own
Terraform config, since state can't bootstrap itself.

## 1. Create a resource group for the backend

```bash
az group create --name rg-tfstate --location eastus
```

## 2. Create a storage account (name must be globally unique)

```bash
az storage account create \
  --name tfstateaksmultienv \
  --resource-group rg-tfstate \
  --sku Standard_LRS \
  --encryption-services blob
```

## 3. Create a container for state files

```bash
ACCOUNT_KEY=$(az storage account keys list --resource-group rg-tfstate --account-name tfstateaksmultienv --query '[0].value' -o tsv)

az storage container create \
  --name tfstate \
  --account-name tfstateaksmultienv \
  --account-key $ACCOUNT_KEY
```
## 4a. Create the App Registration for GitHub Actions OIDC

```bash
az ad app create --display-name "tf-aks-multienv-infra-github"
az ad sp create --id <appId>
az ad app federated-credential create \
  --id <appId> \
  --parameters '{"name":"github-actions-main","issuer":"https://token.actions.githubusercontent.com","subject": "repo:Reeceakhun@84012952/tf-aks-multienv-infra@1338886149:ref:refs/heads/master","audiences":["api://AzureADTokenExchange"]}'
```
> **Note:** always copy the exact `subject claim` value from a failed
> `azure/login` run's log output rather than hand-constructing it — GitHub
> includes numeric org/repo IDs in the token subject
> (`owner@ownerID/repo@repoID`), which isn't obvious from documentation
> examples alone.

Confirm your repo's actual default branch before running this — `main` vs
`master` mismatches (or GitHub's newer `owner@id/repo@id` subject format)
were the single biggest source of failed authentication when setting up
`aks-ephemeral-infra`; see that repo's README for the full troubleshooting
trail if this fails the same way here.

## 4b. Add the OIDC values as GitHub repo secrets

Settings → Secrets and variables → Actions → New repository secret:

| Secret | How to get it |
|---|---|
| `AZURE_CLIENT_ID` | The `appId` returned by `az ad app create` above. If not copied at the time: `az ad app list --display-name "tf-aks-multienv-infra-github" --query "[0].appId" -o tsv` |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` — same value as `aks-ephemeral-infra`, tied to the Azure AD tenant, not this specific app |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` — same value as `aks-ephemeral-infra`, unless using a different subscription |

`AZURE_CLIENT_ID` is the only one of the three that differs from
`aks-ephemeral-infra` — this repo has its own dedicated App Registration
rather than reusing that one, so its access is scoped independently and
can never touch `aks-ephemeral-infra`'s resources.

## 4c. Configure the backend in `provider.tf`

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "tfstateaksmultienv"
    container_name        = "tfstate"
    key                    = "dev.terraform.tfstate"
  }
}
```

The `key` value is what separates state *per environment* — dev, staging,
and prod each get their own key (`dev.terraform.tfstate`,
`staging.terraform.tfstate`, `prod.terraform.tfstate`) so applying to one
environment can never accidentally touch another's state. This is set
dynamically per pipeline run rather than hardcoded — see the plan/apply
workflow for how.

## 5. Authenticate

The GitHub Actions workflow authenticates to this storage account the same
way it authenticates to Azure generally — via OIDC federation, same pattern
as `aks-ephemeral-infra`. No storage account key is stored as a GitHub
secret; the federated identity is granted `Storage Blob Data Contributor`
on this specific storage account.

```bash
az role assignment create \
  --assignee <github-actions-app-id> \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/<sub-id>/resourceGroups/rg-tfstate/providers/Microsoft.Storage/storageAccounts/tfstateaksmultienv
```

## 6. Set up Infracost

1. Sign up at [infracost.io](https://www.infracost.io) (free tier).
2. Get your API key:
```bash
   infracost auth login
```
   (requires the Infracost CLI installed locally — `brew install infracost/tap/infracost` on Mac, or see infracost.io/docs for other platforms)

   Alternatively, copy the API key directly from your Infracost dashboard
   after signing up, without installing the CLI locally.

3. Add it as a GitHub repo secret:

   | Secret | Value |
   |---|---|
   | `INFRACOST_API_KEY` | your API key from step 2 |

No Azure role assignment is needed for this one — Infracost estimates
cost from the Terraform plan's *data* (resource types, sizes, regions),
it doesn't query live Azure pricing APIs against your subscription.
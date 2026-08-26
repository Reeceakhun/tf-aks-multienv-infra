# tf-aks-multienv-infra

Terraform-managed AKS clusters across dev, staging, and prod, with a CI
pipeline enforcing security scanning, cost gating, and approval gates
before changes reach production.

> **Status: in progress.** Core Terraform config (resource group, AKS
> cluster, dedicated node pool) and per-environment `.tfvars` are in
> place. CI pipeline, security scanning, cost gating, approval gates,
> reaper, drift detection, and policy checks are being added next — see
> [Roadmap](#roadmap).

## Why this project

Provisioning infrastructure via direct CLI calls is fast to build but
doesn't reflect how infrastructure is typically managed at scale. This
project uses declarative Terraform with environment-scoped state,
security and cost checks before anything applies, and approval gates
before production changes — the practices a platform team actually runs
on day to day.

## Stack

- **IaC:** Terraform (`azurerm` provider)
- **Cloud:** Azure — AKS, dedicated node pools, resource groups per environment
- **State:** Azure Storage remote backend, one state key per environment
- **Auth:** OIDC federation (Workload Identity), no stored credentials
- **CI/CD:** GitHub Actions (planned)
- **Security/cost tooling (planned):** tfsec, gitleaks, Infracost, Conftest

## Project structure

```
tf-aks-multienv-infra/
├── provider.tf              # azurerm provider, remote backend (not yet wired)
├── variables.tf             # environment, location, node sizing, TTL
├── main.tf                  # resource group, AKS cluster, workloads node pool
├── environments/
│   ├── dev.tfvars
│   ├── staging.tfvars
│   └── prod.tfvars          # ttl_minutes = 0 → opts out of the reaper
└── docs/
    └── backend-setup.md     # remote state + OIDC setup, run once by hand
```

## Design decisions

- **Separate workloads node pool** from the cluster's built-in system
  pool — system pods (CoreDNS, etc.) stay isolated from application
  workloads, which can be resized or replaced independently.
- **`ignore_changes` on node count** for both node pools — without this,
  Terraform would try to "correct" node count back to the `.tfvars` value
  on every plan, fighting any autoscaler or manual intervention that
  legitimately changed it.
- **One Terraform state key per environment**, not one shared state file
  — applying to dev can't accidentally touch staging or prod, since each
  points at a different blob in the same storage account.
- **`prod.tfvars` sets `ttl_minutes = 0`** as a deliberate sentinel value
  — the reaper (not yet built) will treat `0` as "never tear this down,"
  distinguishing prod's persistent lifecycle from dev/staging's ephemeral
  one, using the same tfvars mechanism that already controls node sizing.
- **A dedicated App Registration for this repo's OIDC**

## CI Pipeline

`.github/workflows/terraform-ci.yml` runs on every push and pull request
against `master`.

**`security-scan`** — runs [tfsec](https://github.com/aquasecurity/tfsec)
against all `.tf` files with `soft_fail: false`, meaning a high-severity
finding fails the check and blocks a merge under branch protection — a
gate, not just a report. Runs on PRs specifically so misconfigurations are
caught before code lands on `master`, not after.

**`secrets-scan`** — runs [gitleaks](https://github.com/gitleaks/gitleaks)
against commit history, restricted to `pull_request` events only. This
restriction is deliberate, not a simplification — see Notes below for why
a `push`-triggered version of this check turned out to be a silent no-op
on merge commits.


## Pipeline: Plan & Apply

`.github/workflows/terraform-plan-apply.yml` runs on push/PR to `master`,
and supports manual dispatch with an environment selector.

**`plan`** — runs on every push and PR
1. Installs Terraform, initializes against the remote backend using a
   per-environment state key (`-backend-config="key=dev.terraform.tfstate"`,
   etc.)
2. Runs `terraform plan` against the selected environment's `.tfvars`
3. Uploads the exact plan output as a build artifact

**`apply`** — runs only on pushes to `master`, never on PRs
1. Downloads the *exact* plan artifact `plan` produced — does not
   re-plan, so what gets applied is guaranteed to match what was
   reviewed, not a fresh plan that could have drifted in between
2. Applies it

Both jobs authenticate the `azurerm` Terraform provider via OIDC directly
(`ARM_USE_OIDC` + `ARM_CLIENT_ID`/`ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID`
environment variables), independently of the `az` CLI session `azure/login`
sets up — the `azurerm` provider's default CLI-based auth explicitly
rejects Service-Principal-authenticated CLI sessions, so it needs its own,
separate OIDC handshake.

## Approval gates

`apply` is attached to a GitHub Environment matching whichever
environment was targeted (`dev`, `staging`, or `prod`, selected via
`workflow_dispatch`). `staging` and `prod` have a required reviewer
configured; `dev` does not, so pushes to `master` apply to dev
automatically, while staging/prod only ever change through a manual
trigger that pauses for explicit approval.

### OIDC subject formats

Every distinct way this workflow's identity gets asserted to Azure AD
produces a different token subject, and each one needs its own trusted
federated credential — there's no wildcard match. Discovered these one
`AADSTS700213` failure at a time rather than all at once:

| Trigger | Subject format |
|---|---|
| Push to `master` | `repo:<owner>@<id>/<repo>@<id>:ref:refs/heads/master` |
| Pull request | `repo:<owner>@<id>/<repo>@<id>:pull_request` |
| Job attached to a GitHub Environment | `repo:<owner>@<id>/<repo>@<id>:environment:<name>` |

Five federated credentials exist on this repo's App Registration as a
result: one for push, one for pull_request, and one per environment
(dev/staging/prod). A single "catch-all" credential isn't possible —
each trigger type must be explicitly trusted.


## Reaper

`.github/workflows/reaper.yml` runs on a 15-minute cron (plus manual
dispatch), checking `dev` and `staging` — `prod` is structurally absent
from the matrix, not just filtered at runtime, so no logic error could
ever cause it to be destroyed.

For each environment, it reads the resource group's `created-at` and
`ttl-minutes` tags directly from Azure (not from Terraform state, so this
works even if state is out of sync), computes age, and only runs
`terraform destroy` — against that environment's correct backend state
key — if the TTL has been exceeded. A `ttl-minutes` of `0` (prod's value)
is treated as "never expire," a second, independent safeguard beyond
prod's absence from the matrix.

Verified end to end: confirmed the reaper correctly **skipped** a
resource group at 10 of 20 allowed minutes, then correctly **destroyed**
it once the TTL was exceeded — not just that the workflow ran without
erroring.

## Drift detection

`.github/workflows/drift-detection.yml` runs `terraform plan` against
prod hourly, using `-detailed-exitcode` to distinguish "no changes" (exit
0) from "changes found" (exit 2) from "error" (exit 1) — a plain
`terraform plan` always exits 0 regardless of outcome, so this flag is
what makes automated drift detection possible at all. If drift is found,
it's surfaced as a warning annotation directly on the workflow run
summary, without failing the job or attempting to auto-remediate.

### A real node pool constraint hit while testing this

Applying to prod for the first time (needed to have something real for
drift detection to check against) failed with:
`temporary_name_for_rotation must be specified when updating...
default_node_pool.0.vm_size` (among other properties). This isn't a
config mistake — AKS genuinely cannot change several `default_node_pool`
properties in place; the provider requires an explicit
`temporary_name_for_rotation` so it can create a temporary pool, migrate
workloads, then delete the original. Without this, Terraform refuses the
change outright rather than attempting something destructive silently.
Fixed by adding `temporary_name_for_rotation = "temppool"` to the node
pool block in `main.tf`.
Verified end to end: manually added a tag to prod outside Terraform,
confirmed the next drift-detection run correctly flagged it as a
proposed change, then cleaned up.


## Policy as code

`policy/rbac.rego` (evaluated via [Conftest](https://www.conftest.dev/))
fails the pipeline if a Terraform plan proposes an `azurerm_role_assignment`
granting `Owner` or `Contributor` at subscription scope rather than a
resource group or narrower.

This directly automates a finding made by hand elsewhere in this
portfolio — [`reece-project`](https://github.com/Reeceakhun/reece-project)'s
README documents a `roles/storage.admin` grant that was broader than
necessary, caught on manual review. This policy exists so that class of
issue is caught by CI on every plan, not dependent on a human remembering
to check.

**Scope, stated honestly:** no `azurerm_role_assignment` resources exist
in this repo's Terraform config today — the pipeline's own identity was
granted its role manually via `az`, outside Terraform, during initial
setup (see `docs/backend-setup.md`). This policy is a guardrail against
future changes to this codebase, not something that caught a live
violation here. Verified it works by temporarily adding a
subscription-scoped role assignment on a test branch, confirming the
check failed with the expected deny message, then removing it without
merging.

`policy-check` generates its own Terraform plan independently rather than
depending on the main `plan` job — `plan` is intentionally skipped on
pull requests (see "Pipeline: Plan & Apply"), and a job depending on a
skipped job is itself skipped by default. A policy gate that never runs
on the PRs it's meant to block isn't actually a gate, so this check plans
against `dev.tfvars` on its own, the same pattern already used by
`cost-estimate`.

## Terraform Reference

Auto-generated from the actual `.tf` files by
[terraform-docs](https://terraform-docs.io) — verified in CI on every PR,
never edited by hand. If this section and the real Terraform config ever
disagree, the `docs-check` job fails the PR until `terraform-docs` is
re-run.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.7.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 3.100 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 3.117.1 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_kubernetes_cluster.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster) | resource |
| [azurerm_kubernetes_cluster_node_pool.workloads](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_resource_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.test_violation](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name: dev, staging, or prod | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region for all resources | `string` | `"eastus"` | no |
| <a name="input_node_count"></a> [node\_count](#input\_node\_count) | Number of nodes in the default node pool | `number` | n/a | yes |
| <a name="input_node_vm_size"></a> [node\_vm\_size](#input\_node\_vm\_size) | VM SKU for the default node pool | `string` | n/a | yes |
| <a name="input_ttl_minutes"></a> [ttl\_minutes](#input\_ttl\_minutes) | Minutes before the reaper tears this environment down. Ignored for prod. | `number` | `20` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->

## Running locally

Requires the remote backend and OIDC setup from
[`docs/backend-setup.md`](docs/backend-setup.md) to exist first (run once,
by hand, not by Terraform itself).

```bash
terraform init
terraform plan -var-file=environments/dev.tfvars
```

Swap `dev.tfvars` for `staging.tfvars` or `prod.tfvars` to plan against a
different environment. `terraform apply` is intentionally not documented
here yet — see Roadmap; applying via CI with approval gates in place is
the intended path, not a local `apply` against prod.

## Roadmap
- [ ] Write `NOTES.md` and finish the README's architecture diagram + CV-claim mapping
- [ ] Add `docs/disaster-recovery.md`

## Notes / issues hit along the way

- **`terraform plan` prompted interactively for `environment`, then
  `node_count`** — expected behavior once resources referencing those
  variables existed but before any `.tfvars` file did. Not a bug; resolved
  by adding the `.tfvars` files so `-var-file` makes every plan
  non-interactive going forward.
- **gitleaks passed cleanly on a merge commit despite a known secret being
  present in the merged code.** Verified this wasn't a false negative by
  first confirming detection worked correctly on the originating PR (it
  did — `1 leaks found`, correctly flagged). The gap was specific to the
  `push`-triggered run: `gitleaks-action` runs `git log` with `--no-merges`
  by default, and computes its scan range as "previous branch tip → new
  branch tip." For a non-fast-forward PR merge, that range is exactly one
  commit — the merge commit itself — which `--no-merges` then excludes
  entirely, leaving zero commits scanned. The check still reported
  "success," which is the concerning part: a passing check that scanned
  nothing is more dangerous than a missing check, since it creates false
  confidence. Fixed by restricting `secrets-scan` to `pull_request` events
  only, where the diff range correctly includes the actual changed
  commits. Confirmed the fix by re-testing with a fake secret through a
  fresh PR.
  Re-verified with a fresh test PR: `secrets-scan` correctly failed on the
  PR containing a planted secret, and correctly showed as skipped (not a
  hollow pass) on the subsequent merge to `master`.
- **`terraform: command not found`** — the workflow never installed the
  Terraform CLI; `azure/login` only sets up Azure CLI auth, not Terraform tooling. First fix attempt only added the setup step to the `apply`
  job; `plan` (which runs first, and was the one actually failing) was still missing it. Caught by reading the full workflow file rather than assuming the first patch covered everything.
- **First real prod apply failed on a node pool property change** — see
  the "Drift detection" section above for the full explanation; kept it
  there rather than duplicated here since it's directly tied to that
  testing effort.
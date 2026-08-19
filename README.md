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

- [ ] Wire the remote backend into `provider.tf` (currently using local
      state while core resources were being built)
- [ ] Add tfsec and gitleaks as required CI checks
- [ ] Add a GitHub Actions plan/apply workflow, parameterized by environment
- [ ] Add Infracost cost estimation as a PR check
- [ ] Add GitHub Environments with required reviewers before staging/prod apply
- [ ] Add PR-triggered ephemeral environments (provision on open, destroy on close)
- [ ] Add the reaper (terraform destroy via tags, prod opt-out via `ttl_minutes = 0`)
- [ ] Add scheduled drift detection against prod
- [ ] Add a Conftest policy denying overly-broad role assignments
- [ ] Automate `terraform-docs` generation in CI
- [ ] Write `NOTES.md` and finish the README's architecture diagram + CV-claim mapping
- [ ] Add `docs/disaster-recovery.md`

## Notes / issues hit along the way

- **`terraform plan` prompted interactively for `environment`, then
  `node_count`** — expected behavior once resources referencing those
  variables existed but before any `.tfvars` file did. Not a bug; resolved
  by adding the `.tfvars` files so `-var-file` makes every plan
  non-interactive going forward.

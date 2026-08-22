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

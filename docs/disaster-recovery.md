# Disaster Recovery Approach

This project doesn't implement multi-region failover — for a portfolio
project at this scale, that would be infrastructure built to prove a
point rather than infrastructure serving a real need. What follows is
the DR *plan*: what's actually protected today, what a real incident
would require, and what target recovery numbers this design implies.

## What's actually protected today

- **Terraform state** lives in Azure Storage with locking, separate from
  any environment's own resources — losing an AKS cluster doesn't risk
  losing the record of how to rebuild it.
- **Infrastructure is fully declarative.** Given the state file (or even
  without it, given the `.tf` files and `.tfvars` alone, accepting a
  slower `terraform import`-based recovery), any environment can be
  rebuilt from source, not restored from a backup that could be stale.
- **State storage itself has redundancy** via Azure Storage's built-in
  replication (`Standard_LRS` currently — locally redundant only; see
  "What I'd change" below).

## What a real region-loss scenario would require

1. **Recreate the state backend** in a surviving region (or restore from
   Azure Storage's geo-replication, if upgraded from LRS — see below)
2. **Point `provider.tf`'s backend config at the new storage account**
   and re-run `terraform init`
3. **Re-run `apply`** for each environment against the new region — since
   everything is declarative, this recreates infrastructure rather than
   restoring it, which is slower than a warm-standby failover but
   requires no region-specific manual recovery runbook beyond "run the
   pipeline against a different backend"

## Target recovery objectives (design intent, not measured)

- **RTO (Recovery Time Objective):** ~30–60 minutes for dev/staging — the
  time to re-point the backend and re-run `apply`. Prod would take
  longer given its approval gate is intentionally still required even in
  a recovery scenario, trading recovery speed for avoiding an
  under-pressure bad decision.
- **RPO (Recovery Point Objective):** effectively zero for infrastructure
  *definition* (it's in git, not in the failed region at all) but
  non-zero for any data an actual workload would hold — this project's
  demo app is stateless, so this doesn't currently apply, but any real
  workload built on this pattern would need its own data backup strategy
  layered on top of this infrastructure-recovery plan.

## What I'd change for a production DR posture

- Upgrade the state storage account from `Standard_LRS` to
  `Standard_GRS` (geo-redundant), so state itself survives a regional
  outage without a manual export step
- Store a copy of the OIDC federated credential configuration
  (`docs/backend-setup.md`) as an actual runbook step, not just setup
  documentation — recovery-time is the wrong moment to be re-deriving
  `az ad app federated-credential create` commands from scratch
- Define and actually test an RTO/RPO target, rather than stating one as
  intent — a DR plan that has never been exercised is a hypothesis, not
  a capability

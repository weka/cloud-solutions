# WEKA Converged on AWS — native Ansible

Deploy and operate **converged WEKA clusters on AWS EC2** — WEKA backends
sharing GPU/compute nodes with your workloads — with nothing but Ansible,
the AWS API, and SSM. No SSH keys, no inbound ports, no golden AMIs, no
static inventory files.

```bash
# the whole day-0, after filling weka_vars.yml (see RUNBOOK.md):
ansible-playbook -e @weka_vars.yml cluster.yml
ansible-playbook -e @weka_vars.yml fs.yml
```

## Which package should I use?

| | **This package (Ansible-native)** | [Axon Bash Install](../Axon_Bash_install/README.md) |
|---|---|---|
| Dependencies | Ansible + AWS collections + Session Manager plugin | AWS CLI + bash |
| Configuration | `weka_vars.yml` (one file) | `weka.conf` (one file) |
| Day 0 + core day-2 | ✅ | ✅ |
| Filesystem + POSIX mounts, health gates, maintenance stop/start | ✅ playbooks | manual |
| Rerun/resume semantics | natively idempotent — plain rerun resumes anything | guarded, with documented recovery steps |
| Cross-VPC data-plane ENIs (mgmt/data in different VPCs) | not yet — single-VPC layouts | ✅ automated (`attach-data-enis.sh`) |
| Best for | Ansible shops, AWX/CI integration, full-lifecycle automation | minimal workstations, script-first teams, quick POCs |

Both packages share the same workstation tooling, IAM model, tag-driven
design, and launch templates — moving between them does not require
redeploying (the variable model carries over).

## How it works

- **Native Ansible over SSM.** Every node task runs through the
  `community.aws.aws_ssm` connection — nodes need zero inbound
  connectivity. The UI is reached over an SSM port-forward.
- **Tag-driven membership.** Instances tagged `weka-cluster=<name>` *are*
  the cluster, discovered by the `amazon.aws.aws_ec2` dynamic inventory.
  The same tag scopes the IAM permissions as a security boundary.
- **Runtime topology discovery.** Cores (NUMA-aware, SMT-excluded), data
  NICs, and instance-store NVMe are discovered on each node at deploy time
  and become Ansible facts — the same role runs unmodified on any instance
  type that meets the minimums (local NVMe + ENIs for the core carve).
- **The control node orchestrates.** Cluster-level steps run `run_once`
  against a member; membership and health are resolved from the cluster
  itself before any operation acts.
- **Idempotent end to end.** Rerun any playbook after any failure — agent
  installs, containers, cluster create, drive adds, and password rotation
  are all probe-guarded. A killed deploy resumes with a plain rerun.
- **Guarded day-2.** Scale-in enforces the original-cluster-size floor and
  drains serially; every disruptive operation is health-gated; removals
  verify their end state.

## Playbooks

| Playbook | Purpose |
|---|---|
| `cluster.yml` | Day-0: guards → install → discovery + containers → cluster create → protection → drives → start-io → baseline → password rotation |
| `fs.yml` | Filesystem + wekafs POSIX mount on every member (the cluster is usable after this) |
| `day2-status.yml` | Membership vs inventory, protection, baseline |
| `healthcheck.yml` | 5 read-only health gates (status, protection, rebuild, drives, hot spare) |
| `scale-out.yml` | Adopt tagged candidates; installs WEKA from the running cluster's own dist endpoint (version-matched) |
| `scale-in.yml` | Graceful removal: floor-enforced, health-gated, serialized drive drain; optional Slurm drain hook |
| `node-stop.yml` / `node-start.yml` | Maintenance stop/start of one member (planned reboots) |
| `replace.yml` | Replace a dead/terminated member: auto-detect, confirm, cluster-side cleanup, adopt the replacement |
| `membership.yml` | Shared building block (imported by the day-2 playbooks) |

## Workstation-side tooling (`scripts/`)

| Script | Purpose |
|---|---|
| `generate-launch-template.sh` | Derives the full ENI/EBS layout from `describe-instance-types` and creates the launch template; `describe <type>` prints a capability report |
| `weka-env-preflight.sh` | Read-only account/VPC conformance check; failures print copy-paste `fix:` commands |
| `create-infrastructure.sh` | Optional greenfield helper: SGs, SSM endpoints, IAM role/profile inside an existing VPC |
| `userdata-el.sh` | Launch-template user data for RHEL-family AMIs (SSM agent + SELinux) |

## Requirements

- **Control node**: Linux with Python ≥ 3.9, `ansible-core`, the
  `amazon.aws` + `community.aws` collections, AWS CLI v2 with the
  Session Manager plugin, and credentials per `RUNBOOK.md` §IAM.
  (macOS works with caveats — see the RUNBOOK appendix.)
- **Nodes**: any instance type with local NVMe and ENI budget for
  `1 mgmt + 1 per WEKA core`; kernel ≤ 6.8 for WEKA 4.4.x; egress to
  distro package repos (NAT or proxy).
- **WEKA tarball** in an S3 bucket in your account.

Validated on Ubuntu 22.04/24.04, Amazon Linux 2023, and Rocky 9.5, across
i3en/i7ie/m5d/g4dn/p6 platforms, including greenfield VPCs, kill/resume
cycles, and dead-node replacement. See `docs/MIGRATION-HISTORY.md` for the
full validation record.

## Start here

**[RUNBOOK.md](RUNBOOK.md)** — prerequisites, IAM, environment setup,
the day-0 walkthrough, every day-2 operation, and troubleshooting.

# Migration + validation history (record)

This is the development log of the bash-to-native-Ansible migration and
its validation program, preserved for the record. **End users: see
../README.md and ../RUNBOOK.md** — nothing here is required reading.

# native/ — Phase 1 of the native-Ansible migration

Status: **in development — not shipped, not yet live-validated.**
The production solution remains `cs-package/` unchanged; nothing here is
referenced by it. See
`cs-package` PR docs (`docs/native-ansible-migration.md` in the published
package) for the full migration plan.

## What exists (Phase 1 scope)

- `roles/weka_node/` — the node role skeleton (structure converged with
  [weka-oci-ansible](https://github.com/j2joi/weka-oci-ansible))
- Node **preflight** ported from `cs-package/scripts/weka-preflight.sh` into
  role task files (`preflight*.yml`), preserving:
  - every check and its PASS/WARN/FAIL classification
  - the exact `[PASS]/[WARN]/[FAIL]` line output and
    `##### RESULT: N pass / N warn / N fail #####` footer
  - the gate semantics: any FAIL fails the play for that host
- `preflight.yml` playbook — runs the role against tag-discovered nodes
- Dynamic inventory (`inventory/weka_ec2.aws_ec2.yml`) — membership by
  `weka-cluster` tag, no static inventory files
- SSM connection wiring (`group_vars/all.yml`) — `community.aws.aws_ssm`,
  no SSH anywhere

## Phase 0 spike: PASSED (2026-08-03)

Validated live on 2× i3en.2xlarge (AL2023, generator-built template, tag
`weka-scale-test`): the full ported preflight ran over `community.aws.aws_ssm`
— 21 pass / 0 warn / 0 fail per node, output byte-compatible with the bash
preflight, gate semantics intact. **38 tasks/host completed in ~70s total**
(hosts in parallel) — transport latency is acceptable. No SSH anywhere.

### Control-node requirements learned from the spike

- **Linux control nodes: no special handling.** Everything below is
  macOS-only.
- **macOS: use a venv with Python <= 3.13** (`uv venv --python 3.12`,
  `pip install ansible-core boto3`, `ansible-galaxy collection install
  amazon.aws community.aws`). Homebrew's Python 3.14 ansible kills forked
  workers outright.
- **macOS: the dynamic inventory and forked workers cannot share a
  process.** Running the `aws_ec2` inventory plugin in the same invocation
  as `aws_ssm` connections crashes workers (fork after boto3 threads).
  Workaround: snapshot the inventory first, then run plays against the
  static snapshot:

  ```bash
  ansible-inventory -i inventory/weka_ec2.aws_ec2.yml --list --yaml > /tmp/weka-hosts.yml
  ansible-playbook -i /tmp/weka-hosts.yml -e ssm_transfer_bucket=<bucket> preflight.yml
  ```

- `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` in the environment is cheap
  insurance on macOS.
- The `aws_ssm` plugin resolves credentials itself; with SSO named
  profiles either set `ansible_aws_ssm_profile`, or export static env
  credentials (`eval "$(aws configure export-credentials --profile X
  --format env)"`).
- **Set the transfer bucket explicitly** (`-e ssm_transfer_bucket=...`).
  A wrong/placeholder bucket surfaces as a misleading
  `Failed to get bucket region: ... 404` from every task.

## Phase 2 (install): PASSED (2026-08-03)

`install.yml` validated live on 2× i3en.2xlarge (AL2023): build deps (incl.
the EL vault kernel-devel and AWS CLI v2 bundle fallbacks as native tasks),
/opt/weka volume handling, and the WEKA agent install (4.4.10.80 from S3 via
the instance role). First run: agent installed on both nodes in ~2.5 min,
failed=0. **Idempotence rerun: `changed=0`, "agent present, skipping
install", 40s** — the rerun-safety that required hand-rolled guards in the
bash path is structural here.

## Phase 3 (discovery + containers): PASSED (2026-08-03)

The validated bash `discover()` moved **verbatim** into
`roles/weka_node/files/discover.sh` (NUMA pairing, pin/exclude, NVMe
selection with in-use skipping, NIC role split, per-role DPDK `--net` args)
and emits JSON that becomes `weka_topology` host facts. Container creation
(`container.yml` shared by drives/compute/frontend entrypoints) consumes the
facts. Live-validated: drives0 **Running (STEM mode)** on both nodes with
correct topology, idempotent rerun `changed=0` ("already exists -- skipping").
The bash cleanup phase is ported with improved semantics (`cleanup.yml`:
no-op when drives0 exists instead of failing the run — removes the fresh
agent's port-14000 default container otherwise).

compute/frontend entrypoints are written but validate with Phase 4 (they
join a cluster, which needs >= 5 nodes and the orchestration playbook).

## Phase 4 (cluster orchestration): PASSED (2026-08-03)

`cluster.yml` — the full day-0 as seven plays (install → drives → create →
compute → frontend → adddrives → finalize). The control node orchestrates
directly (`run_once` + `delegate_to` the first sorted host): **the bash
orchestrator election and its bug class no longer exist.** Validated live on
6× i3en.2xlarge: `status: OK, protection: 3+2 (Fully protected), 18 backend
containers UP, 12 drives UP, IO STARTED` — ~10 minutes from fresh boots,
including a mid-run failure + plain rerun that resumed cleanly (completed
phases skip: agent, containers, cluster create, drive adds, rotation are all
probe-guarded). Idempotence upgrades over the bash path: create skips when a
cluster exists, rotation is once (secret-existence check), adddrives counts
attached drives, logins are secret-first for post-rotation reruns.

## Phase 5 (day-2 + parity-plus): PASSED (2026-08-03)

New playbooks, all live-validated on a 6→7→6 node cycle:

- `membership.yml` — classifies inventory into `weka_members` /
  `weka_candidates` by cluster view, elects a **vantage host** (proven
  cluster view) that all cluster queries delegate to
- `day2-status.yml`, `healthcheck.yml` (the 5 OCI-parity gates, with
  `-e weka_skip_health_checks=true` bypass)
- `fs.yml` — filesystem + wekafs POSIX mounts on every member (validated:
  `default 94G /mnt/weka`) — the OCI-parity piece day-0 lacked
- `scale-out.yml` — health-gated adoption of candidates, WEKA installed
  from the **cluster dist endpoint**; the primary is always drawn from
  members (the bash election flaw cannot exist); adddrives targets ALL
  nodes so partial adoptions self-heal
- `scale-in.yml` — floor-enforced (baseline parameter; live-validated
  REFUSED at the floor), health-gated, serialized drive drain
  (deactivate → poll → UUID remove), tolerant container removal with
  hard end-state verification, local wipe + re-tag; optional Slurm
  drain hook (**UNVALIDATED** — no Slurm in the test env)

Hardening from live findings: container creation verifies Running with
one restart retry (setup can return success while the container crashes);
cleanup is membership-aware (a candidate's local containers are orphans
and get wiped; only members keep-and-skip).

## Phase 6 gauntlet: COMPLETE — 9/9 (2026-08-04)

| Scenario | Status | Evidence / hardening produced |
|---|---|---|
| Stripe-guard negative | ✅ PASS | 6+2-on-6 refused in 1.1s, zero node work (guard moved to a pre-play) |
| Rocky 9.5 cold deploy | ✅ PASS | cluster OK, 3+2 fully protected. Hardening: explicit `weka-agent` service start + **readiness wait** (installer doesn't start the agent on Rocky; touching state mid-first-init truncates the 2GB logs.loop and the agent crash-loops), container **create-retry with cleanup** (loop-device busy during squashfs prepare) |
| Drive-skip (deliberate LVM PV) | ✅ PASS | cluster formed with **11 drives** (trapped device skipped), fully protected |
| Rocky SSM bootstrap via generator `USER_DATA_FILE` | ✅ PASS | 6/6 SSM-online in ~3.5 min from a generator-built template |
| Ubuntu 22.04 deploy | ✅ PASS | cluster OK, 3+2 fully protected. Hardening: probe/gate tasks flipped from the `command` module to `shell` — `command -v` is a shell builtin; it only worked on RHEL-family via their `/usr/bin/command` shim, and on Ubuntu mis-read errors as "binary absent" |
| Greenfield end-to-end | ✅ PASS | zero-to-cluster: VPC plumbing → create-infrastructure.sh → generator → native cluster.yml through a brand-new NAT; **plus the multi-core carve (2/3/2)**: CpuSpecList 1-7,13-19, cluster OK 3+2 fully protected. Environment fully dismantled after |
| Rerun-after-kill matrix | ✅ PASS | SIGKILL mid-install + SIGKILL mid-compute-create; plain reruns resumed to OK/3+2. Hardening: **per-drive tolerant adds** (a killed add can claim a device locally without registering it) + registered-count verification; **protection update made idempotent** (rerun after drives are added must not re-issue cluster update) |
| Larger fleet / proportional NIC split | ✅ PASS | 6× i3en.6xlarge: 7 data NICs split across roles (kill-matrix fleet); multi-core-per-role covered by the greenfield 2/3/2 run |
| Linux control node | ✅ PASS | EC2 AL2023 controller, instance-role creds, **dynamic inventory direct** (no snapshot), day2-status over aws_ssm to 6 nodes, failed=0 — no macOS caveats exist on Linux. (IAM note: `SSM-SessionManagerRunShell` is an account-scoped document ARN) |

Test-infra lesson (not a code bug): cloning a launch template across AMIs
with different root device names silently strands the root-volume sizing —
always regenerate templates through the generator, which reads the AMI's
root device.

## Entrypoint completion (2026-08-04): ALL day-2 entrypoints validated

- `node-stop.yml` / `node-start.yml` — ✅ live cycle: stop → cluster
  REBUILDING (15/18 containers) → start → OK + fully protected
- `scale-in.yml` Slurm drain hook — ✅ mechanics validated against mocked
  `scontrol`/`squeue` (delegation, drain loop; invocation logged).
  Real-Slurm semantics remain a documented exception until a customer
  environment provides one.
- `replace.yml` — ✅ validated against a genuinely terminated member:
  auto-detects dead members (cluster table vs inventory), requires
  `-e confirm_dead_ip=`, cluster-side cleanup, adopts the replacement via
  the health-bypassed scale-out flow, rebuilds to fully protected
- Ubuntu control-plane hardening from this cycle: POSIX-only shell in all
  playbook tasks (dash is /bin/sh on Ubuntu: no here-strings, no
  `${var//}` substitution), `ansible_aws_ssm_timeout: 900` (the 60s
  default drops hosts as UNREACHABLE mid-apt/mid-download)

## What remains before cutover (docs + packaging, no code)

- ANSIBLE-RUNBOOK rewrite around the native flow
- Package `native/` into the shipped artifact; bash path freeze
- Role/variable convention review with the weka-oci-ansible maintainer

## How to run (once the spike validates the transport)

```bash
cd native
# 1. edit inventory/weka_ec2.aws_ec2.yml   (region + cluster tag value)
# 2. edit group_vars/all.yml               (SSM transfer bucket)
# 3. thresholds/carve come from the same variables as cs-package:
ansible-playbook -e @../cs-package/ansible/weka_vars.yml preflight.yml
```

Requires: `amazon.aws` + `community.aws` collections, AWS credentials,
session-manager-plugin, and an S3 bucket the `aws_ssm` connection can use
for file transfer (both the operator and the instance role need access —
the WEKA install bucket qualifies).

## Design notes

- Check results accumulate per-host in `pf_results` (list of
  `{level, msg}`); reporting and gating are separated from checking, so
  the output contract stays stable while checks evolve.
- Shell probes are kept where the bash used probes (package dry-runs,
  IMDS, sysfs, vault/bundle reachability) — parity first, idiom second.
  Facts replace shell only where Ansible facts are exact equivalents
  (kernel, SELinux, core counts, MemTotal).
- Variable names reuse the `weka_vars.yml` contract (`drive_cores`,
  `compute_cores`, …) so a customer's existing vars file drives this path
  unmodified — invariant #1 of the migration plan.

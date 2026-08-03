# WEKA Converged Deployment on AWS — Ansible Runbook

The Ansible-driven path through this package, for environments where
deployments must run through automation rather than hand-executed scripts.
It deploys the same architecture as [RUNBOOK.md](RUNBOOK.md) — that document
remains the reference for the environment prerequisites (§3), IAM policies
(§4), AMI/kernel requirements (§5), and troubleshooting of the underlying
deployment (§8). This runbook covers everything Ansible-specific.

**How it works:** two playbooks wrap the package's tooling. `site.yml` takes
you from an empty account (with prerequisites in place) to a running WEKA
cluster; `day2.yml` runs the lifecycle operations. Both run entirely on the
Ansible control node against the AWS API — because all orchestration is SSM,
there is **no inventory, no SSH keys, and no network connectivity to the
cluster subnet required.** Every deployment step's success criteria are
expressed as task conditions, so failures stop the play with the evidence in
the task output.

---

## 1. Control node requirements

- `ansible-core` 2.14+ (only `ansible.builtin` modules are used — no
  collections to install)
- AWS CLI v2, authenticated as an identity carrying
  `iam/operator-policy.json` (see RUNBOOK §4)
- `python3` (used by the launch-template generator)
- This package, unzipped; run playbooks from the `ansible/` directory
  (the shipped `ansible.cfg` there enables YAML task-result rendering so
  status output and next-steps commands are copy-paste friendly)

## 2. One-time environment setup

Per RUNBOOK §3–§5, before any playbook run. Start by checking what is
already in place — read-only, fails on any missing prerequisite:

```bash
ansible-playbook -e @weka_vars.yml envcheck.yml
```

(site.yml also runs this same gate automatically as its first step.)

1. Environment prerequisites in place: subnet, security groups, instance
   profile, SSM/S3/Secrets Manager connectivity, capacity reservation.
   **Greenfield environments** missing the SGs / SSM endpoints / IAM role can
   create them through Ansible: fill the "greenfield infrastructure" block in
   `weka_vars.yml` and run

   ```bash
   ansible-playbook -e @weka_vars.yml infra.yml
   ```

   then copy the printed ids back into `weka_vars.yml` (subnet_id, sg_ena,
   sg_efa, instance_profile_arn). It creates resources inside an existing VPC
   only — it does NOT create a VPC, IGW, NAT, or S3 endpoint, so general
   egress (RUNBOOK §3.5) remains your platform team's job.
2. `iam/instance-policy.json` filled and attached to the instance role;
   your cluster name in its tag condition (RUNBOOK §4 — this is the one
   value Ansible cannot template for you).
3. WEKA tarball uploaded to your S3 bucket, bucket granted in the instance
   policy's `WekaDistroDownload` statement.
4. AMI chosen with kernel ≤ 6.8 (or pinned — RUNBOOK §5).

## 3. Configure: `ansible/weka_vars.yml`

The single file your team edits — the Ansible equivalent of `weka.conf`
(playbooks render one from the other, so the two never diverge). Copy it per
cluster (`cp weka_vars.yml prod_cluster.yml`) and fill:

| Variable | Meaning |
|---|---|
| `aws_region`, `cluster_name` | Identity. `cluster_name` must match the IAM tag condition |
| `instance_type`, `ami_id`, `subnet_id`, `sg_ena`, `sg_efa`, `instance_profile_arn` | Your existing environment (RUNBOOK §3). `sg_efa` empty on non-GPU types |
| `launch_template_name` | Explicit template name (the launch task uses it) |
| `expected_nodes`, `stripe_data`, `stripe_protection`, `hot_spares` | Cluster sizing. `DATA+PROTECTION ≤ nodes`; ≥5 nodes minimum |
| `drive_cores`, `compute_cores`, `frontend_cores` | WEKA core carve — drives the ENI count (one data ENI per core). Not sure what fits? `bash ../scripts/generate-launch-template.sh describe <type>` prints the type's max carve and a suggested split |
| `drives_per_node` | 0 = all instance-store NVMe; N = only N (NUMA-balanced) |
| `weka_core_ids`, `excluded_core_ids` | Core placement for Slurm coexistence (RUNBOOK §4); the install output includes the `CpuSpecList` either way |
| `weka_opt_volume_gb` | Dedicated `/opt/weka` EBS: `"auto"` (48 GB + 10/core), N GiB, or 0 |
| `root_volume_gb` | Root EBS size |
| `weka_install_s3` | `s3://bucket/key` of the WEKA tarball |
| `launch_instances` | `false` if your own tooling launches the nodes from the template |
| `capacity_reservation_id`, `capacity_block` | Set both for capacity blocks; only the id for a plain ODCR; neither for on-demand |

## 4. Day 0 — deploy the cluster

```bash
cd ansible
ansible-playbook -e @prod_cluster.yml site.yml
```

Task-by-task, with what you should see:

1. **Render weka.conf** — writes the package config from your vars. `ok`.
2. **Generate/create launch template** — validates your instance type
   (local NVMe, ENI budget vs carve, subnet capacity, EFA SG) and creates
   the template. The next task prints the validation summary: `[ok]` lines
   and the ENI layout. A `[FAIL]` here stops the play — fix the reported
   input. Re-running after a config change is safe: the layout is saved as
   a **new default version** of the existing template.
3. **Launch the cluster nodes** — skipped when `launch_instances: false`.
4. **Wait until all nodes are SSM-online** — retries up to 10 minutes.
   Stuck at 0? The subnet has no SSM path (RUNBOOK §3.4) or the instance
   profile is missing `AmazonSSMManagedInstanceCore`.
5. **Preflight every node** — the gating step. The play fails unless every
   node reports `##### RESULT: … 0 fail`. Each node's full conformance
   report is in the task output; every FAIL maps to a fix in RUNBOOK §8.
   Nothing has been installed at this point.
6. **Install** — runs `deploy.sh install`: ships the installer to the
   elected orchestrator over SSM and drives all phases (install → cleanup →
   drives → cluster create → protection → compute → frontend → drive add →
   start-io). Expect 8–15 minutes. **Do not log into the WEKA UI during
   this step.**
7. **Show cluster status and next steps** — also saved verbatim to
   `ansible/weka-install-<cluster>.log` for copy-pasting — ends with `weka status` showing
   `status: OK` / `Fully protected`, plus ready-to-paste commands with real
   values: Secrets Manager credential retrieval, the SSM port-forward to a
   live backend for the UI (`https://localhost:14000`), and — if you run
   Slurm on these nodes — the exact `CpuSpecList` to reserve.

`PLAY RECAP` should read `failed=0`.

## 5. Day 2 — operate the cluster

```bash
ansible-playbook -e @prod_cluster.yml -e weka_op=status day2.yml
ansible-playbook -e @prod_cluster.yml -e weka_op=scale-out day2.yml
ansible-playbook -e @prod_cluster.yml -e weka_op=scale-in -e weka_target=i-0abc123 day2.yml
ansible-playbook -e @prod_cluster.yml -e weka_op=replace  -e weka_target=i-0abc123 day2.yml
```

- **status** — membership vs tags, baseline, health. Read-only
  (`changed=0`); safe for scheduled runs / AWX health checks.
- **scale-out** — launch additional instances from the same launch template
  first (they are born tagged), then run. Adopts every tagged non-member;
  new nodes install **from the running cluster's own distribution
  endpoint**, so they join at the cluster's current version even after
  manual upgrades. Idempotent — interrupted runs can simply be re-run.
- **scale-in** — serialized graceful removal (drain → remove → local wipe).
  Refuses to shrink below the original cluster size or break the stripe.
  The play output ends with "safe to terminate" — **EC2 termination is
  deliberately left to you** (add your own `ec2_instance` task if desired).
- **replace** — for a failed node: launch the replacement, then run. Adds
  the new node while degraded, removes the dead one, waits for full
  protection. `--remove-first` semantics and the `NODE_IP` override for
  already-terminated nodes are described in RUNBOOK §7.

Credentials for all day-2 operations come from Secrets Manager
automatically — nothing to pass.

## 5b. Teardown — destroy the cluster

```bash
ansible-playbook -e @prod_cluster.yml -e confirm=<cluster_name> teardown.yml
```

Terminates every instance carrying the cluster tag and deletes the
deployment artifacts (baseline parameter, admin secret, launch template).
**All cluster data is lost.** The play refuses to run unless `confirm`
exactly matches your `cluster_name` — pass it explicitly every time; it is
deliberately not a variable you can leave in a vars file. Idempotent: re-runs
on an already-clean environment report "was already gone" and succeed.

## 6. Re-run and failure semantics

- **`site.yml` against a live cluster fails safely** at the install step —
  the installer refuses to run over existing cluster containers (data
  protection by design). To rebuild: teardown per RUNBOOK §8, re-run.
- **A failed play is resumable by re-running it** — every step before the
  failure is idempotent (config render, template versioning, launch skip,
  preflight).
- Task failures carry the underlying evidence: preflight failures include
  each node's report; install failures include the failing node's output
  tail and the log location (`/tmp/weka-run.log` on the orchestrator).
- Diagnose deployment-level errors with RUNBOOK §8 — the Ansible layer adds
  no failure modes of its own, it only surfaces them earlier.

## 7. AWX / Ansible Automation Platform notes

Nothing in the playbooks is CLI-specific: create a project from this
package, job templates for `site.yml` and `day2.yml`, and a survey (or
extra-vars) supplying `weka_vars` values and `weka_op`/`weka_target`. AWS
credentials via a credential type that exports the standard environment
variables. A scheduled `weka_op=status` job makes a serviceable health
check (`changed=0`, fails if the cluster or SSM path is unhealthy). The
control node's execution environment needs the AWS CLI and python3, same as
§1.

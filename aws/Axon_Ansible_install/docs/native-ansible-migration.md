# Migration plan: native Ansible node execution

Status: **proposed** (not started). This documents the plan to move the
node-side logic from the embedded bash payloads (`install/weka-ssm-install.sh`,
`install/weka-day2.sh`) to a native Ansible role, without sacrificing any
current functionality or end-user experience.

## Motivation

The workstation-side layer (env preflight, greenfield infra, launch-template
generation, gating, UX) is sound and unchanged by this plan. The foundational
weakness is node-side: two ~800-line bash programs shipped via SSM
send-command. Consequences observed in live deployments:

- Fixes are string-patches into a monolith, not edits to small task files
- Idempotence is hand-rolled per phase; the gaps are where reruns hurt
- No unit of testability smaller than "run the whole phase on a real instance"
- Customers can read the node logic but cannot safely extend it
- The structure diverges from the OCI sibling project
  ([weka-oci-ansible](https://github.com/j2joi/weka-oci-ansible)), which is a
  clean role-based layout worth converging with for the Axon program

## Target architecture

| Layer | Today | Target | Change? |
|---|---|---|---|
| Entry points / UX | `envcheck → infra → site → day2 → teardown`, one `weka_vars.yml` | identical names, identical vars file | No |
| Env preflight, infra, generator, IAM | workstation bash (cloud-API tools) | unchanged | No |
| Node discovery + phases | bash heredocs via `ssm send-command` | `weka_node` role (task files per phase) executed natively over SSM | Yes |
| Orchestration | node-side self-elected orchestrator fans out SSM | control node orchestrates directly (`run_once` / `delegate_to`); election removed | Yes |
| Connectivity | SSM send-command | `community.aws.aws_ssm` connection plugin + `amazon.aws.aws_ec2` dynamic inventory keyed on the `weka-cluster` tag | Yes |
| Bash path (`deploy.sh` + installers) | primary | frozen fallback, critical-fixes-only | Kept |

No SSH ever appears: the SSM connection plugin preserves the zero-inbound
design, and dynamic inventory preserves tag-driven membership (no inventory
files for the customer to maintain).

## Phases

### Phase 0 — Spike + decision gate (~1 day)
Prove `aws_ssm` connection + dynamic inventory on a 2-node fleet: sudo
behavior, output capture, per-task latency at fan-out, and the plugin's S3
file-transfer bucket requirement (verify the existing install bucket can
double up; add needed statements to both IAM policies).
**Exit criteria:** a trivial role runs on tagged nodes with no SSH and
acceptable speed. If the plugin disappoints, fall back to role tasks rendered
and dispatched via send-command — decided here, cheaply.

### Phase 1 — Role skeleton + node preflight (~1 day)
Create `roles/weka_node/` mirroring the OCI repo's structure (deliberately —
shared conventions serve the Axon program). Port the node preflight first:
read-only, zero blast radius, exercises the whole toolchain. `site.yml`'s
preflight task swaps to the role; output format and the "every node 0 fail"
gate semantics kept identical.

### Phase 2 — Install phase (~1–2 days)
Build deps, AWS CLI bundle fallback, vault kernel-devel fallback, `/opt/weka`
volume, WEKA agent install — as task files with native idempotence
(`creates:`, `stat`+`when`, `package:`). Hand-rolled rerun guards become
structural.

### Phase 3 — Discovery + container phases (~2–3 days, the heart)
Discovery (NUMA pairing, core/NIC allocation, NVMe selection with the in-use
and naming-skew hardening) is NOT rewritten in this phase — the validated bash
moves intact into `roles/weka_node/files/discover.sh`, executed by the role,
returning JSON that becomes host facts. The consumers (drives/compute/frontend
container tasks) become native. Rewriting discovery as a Python module is a
separate optional later phase, only after parity is proven.

### Phase 4 — Cluster orchestration (~1–2 days)
Cluster create, stripe guard, protection, adddrives, start-io, baseline,
password rotation move into `site.yml` as `run_once`/`delegate_to` tasks
against the first sorted member. The orchestrator election — and its whole
bug class (partial-fleet race, scale-out candidate winning the election) — is
eliminated rather than ported: the control node IS the orchestrator.

### Phase 5 — Day-2 + parity-plus (~2–3 days)
Port scale-out / scale-in / replace / status as role entrypoints, keeping the
scale-in floor and dist-endpoint installs. Then close the gaps the OCI
comparison exposed: pre-removal health gates, maintenance node-stop, optional
Slurm drain, filesystem creation + POSIX mounts. The migration should end
ABOVE current functionality, not at it.

### Phase 6 — Validation gauntlet + cutover (~2–3 days, cheap fleets)
The native path must pass everything the bash path has ever passed: cold day-0
(Ubuntu 22.04/24.04, Amazon Linux 2023, Rocky 9.x), rerun-after-partial-failure
idempotence, full day-2 cycle, greenfield end-to-end, cross-VPC, drive-skip
scenarios (deliberately LVM'd node), stripe-guard refusal. Only then:
ANSIBLE-RUNBOOK rewrite, package re-cut, bash path documented as fallback.

## Non-negotiable invariants (the "no sacrifice" contract)

1. Same five commands, same `weka_vars.yml` — existing vars files work
   unmodified.
2. No SSH, no inbound ports, no static inventory; tag = membership.
3. Every guard survives: stripe-fits-nodes, scale-in floor, teardown
   confirmation, cleanup protection, drive-claim safety.
4. Preflight gate semantics and the `fix:` remediation UX unchanged.
5. Output UX: terminal-visible progress + saved install log, same next-steps
   block.
6. The bash path ships alongside until a full release cycle after cutover —
   it is also the air-gap / minimal-workstation story.

## Risks

- **`aws_ssm` plugin is the long pole**: chattier than send-command (per-task
  sessions), known rough edges (S3 staging, become handling). Phase 0 exists
  to fail fast; the send-command-dispatched-role fallback keeps the plan
  viable either way.
- **Discovery regression** is the scariest surface — mitigated by moving the
  validated script verbatim, not rewriting it.
- **Two paths during transition** — mitigated by freezing bash except for
  critical fixes and running the validation matrix against both.

## Effort

Roughly 10–14 focused working days, structured so every phase lands
independently shippable — stopping after Phase 2 still yields real
maintainability gains.

First coordination milestone: agree on shared role/variable conventions with
the weka-oci-ansible maintainer before Phase 1 locks the skeleton.

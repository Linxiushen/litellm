# Buildkite per-SHA e2e pipeline (litellm-poc)

Canonical home for the Buildkite `litellm-poc` pipeline (org `berriai-1`). These files cannot live in the public litellm repo: they carry internal hostnames (stage ALB, ElastiCache endpoint, ECR account, in-cluster Jaeger DNS) and the CI mechanics are intentionally not public.

The flow, given a litellm commit SHA typed into the input step:

1. `gate-gha.py` waits for the GHA required checks on that SHA, reading the required contexts from the same ruleset that governs merges into `litellm_internal_staging`, and fails closed on missing checks
2. `build-image.sh` ensures `litellm/gateway:e2e-<sha>` exists in ECR: skip if present, re-tag a matching nightly, or shallow-fetch the SHA and build
3. `build-runner-image.sh` ensures `litellm-e2e:e2e-<sha>` exists in ECR: skip if present, else build from the bundled litellm-auto Dockerfile (`runner/`, snapshot commit in `runner/.litellm-auto-revision`) with `LITELLM_REF=<sha>`, verify the baked `/app/e2e/.litellm-revision` equals the SHA, and push. No nightly re-tag path: nightly tags do not encode the litellm SHA they baked
4. `deploy-ephemeral` helm-installs a throwaway proxy stack (2 replicas + bundled Postgres + bundled Redis, `e2e-ephemeral-values.yaml`) into the stage EKS `litellm` namespace, instance-labelled by release name so ArgoCD ignores it
5. `e2e-upload` reads the SHA meta-data on an agent and `buildkite-agent pipeline upload`s `step-e2e-run.yml`, which carries `e2e-run` + `e2e-teardown`; the SHA is meta-data set after the initial upload, so a static podSpec image field can never carry it
6. `e2e-run` executes the full e2e suite (from the per-SHA runner image) against that ephemeral stack; results ship to Buildkite Test Engine attributed to the input SHA via the baked revision file
7. `e2e-teardown` always runs: captures evidence, `helm uninstall`, deletes leftover PVCs
8. Manual QA block, then a publish placeholder where project-releaser's promotion will plug in

`runner/` is a snapshot of BerriAI/litellm-auto (Dockerfile, entrypoint.sh, .dockerignore) because the Buildkite agents hold no token for that private repo; the Dockerfile itself only fetches the public litellm repo. When litellm-auto's Dockerfile changes, re-copy the three files and bump `runner/.litellm-auto-revision`

How it runs today: the Buildkite pipeline's checkout repo is `BerriAI/litellm`, and builds are launched with `bk preflight run` from a litellm worktree whose untracked `.buildkite/` holds these files (paths inside `pipeline.yml` assume the litellm repo root). To run it, copy this directory into a litellm checkout as `.buildkite/` and run `bk preflight run -p litellm-poc`. Until the pipeline reads from this repo directly, treat this copy as the reviewed source of truth and sync edits both ways.

Prerequisites living outside this repo: Buildkite cluster secrets `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (ECR push, to be replaced by OIDC; the `buildkite-e2e-ecr` IAM user's inline policy must cover BOTH `repository/litellm/gateway` and `repository/litellm-e2e`), `GITHUB_TOKEN` for the gate, an agent-stack-k8s controller in the stage cluster's `litellm` namespace serving queue `eks-stage`, and a RoleBinding granting the job pods `edit` in that namespace (accepted PoC shortcut, least-privilege replacement tracked)

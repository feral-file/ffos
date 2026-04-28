# FFOS - Arch Linux ISO Build Repository

FFOS is the centralized build repository for FF1 operating system images. It coordinates Arch ISO generation, FFOS component packaging, local player packaging, pacman repository updates, and image upload/signing.

The build uses source and user data from companion repositories:

```text
ffos-user/components/  -> component pacman packages -> R2 {branch}/os/x86_64/
ffos-user/users/       -> ISO home directory content
ff-player              -> optional feral-player static package
ffos/archiso-ff1       -> Arch ISO profile
```

## Repository Structure

```text
ffos/
|-- .github/actions/setup-pacman/       # Shared pacman snapshot setup action
|-- .github/workflows/                  # GitHub Actions workflow definitions
|-- archiso-ff1/                        # Archiso profile and package lists
|-- docs/                               # Supporting system documentation
|-- scripts/verify.sh                   # Repo-wide non-mutating verification
|-- Makefile                            # Local command entry points
`-- README.md
```

## Local Verification

Run the same non-mutating verification path used by CI:

```sh
make verify
```

`make verify` calls `scripts/verify.sh`, which checks shell syntax, runs ShellCheck, validates GitHub workflow YAML shape, confirms the CI verification workflow calls the same script, and confirms this README lists every workflow file.

Required local tools:

- `bash`
- `ruby`
- `shellcheck`
- `make`

The verification path does not build packages, build an ISO, sign artifacts, upload to R2, or require repository secrets.

## GitHub Actions Verification

`.github/workflows/verify.yml` runs the same `scripts/verify.sh` path on pull requests, pushes to long-lived branches, and manual dispatch.

This workflow is intended for fast repository configuration validation. Release/package/image workflows remain manual or reusable because they require privileged containers, external repositories, repository secrets, Cloudflare R2 access, and AWS KMS signing.

## Workflow Inventory

### Validation

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `verify.yml` | `pull_request`, selected `push` branches, `workflow_dispatch` | Non-mutating repository verification shared with `make verify`. |

### Full image builds

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `build-image-to-cf.yml` | `workflow_dispatch` | Full FFOS image pipeline: build component packages, build the local player package, update the pacman repo DB, build/sign/upload the ISO, and update version metadata. |
| `pure-build-image-to-cf.yml` | `workflow_dispatch` | Build/sign/upload an FFOS image using packages that already exist in the remote pacman repo. |
| `build-image-from-tags.yml` | `workflow_dispatch` | Build an image from explicit `ffos`, `ffos-user`, and optional `ff-player` refs. Component/player packages are built locally for the image path instead of uploaded first. |

### Manual package and repository operations

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `manual-build-components.yaml` | `workflow_dispatch` | Build and upload one selected `ffos-user` component package. |
| `manual-build-feral-player.yaml` | `workflow_dispatch` | Build and upload the `feral-player` pacman package from an `ff-player` ref. |
| `manual-push-pacman-repo.yaml` | `workflow_dispatch` | Rebuild and upload the remote pacman repository database from packages already in R2. |

### Reusable workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `build-components.yaml` | `workflow_call` | Package one `ffos-user` component and upload the package/signature to R2. |
| `build-feral-player.yaml` | `workflow_call` | Build the `ff-player` static export, package it as `feral-player`, and upload package artifacts to R2. |
| `pacman-repo.yaml` | `workflow_call` | Download packages from R2, rebuild/sign the pacman DB, and upload the DB files. |
| `permission-check.yaml` | `workflow_call` | Restrict privileged staging/release workflow runs to repository admins. |
| `resolve-container.yaml` | `workflow_call` | Resolve the Arch Linux container image for a requested pacman snapshot. |

## Common Manual Inputs

The manually dispatched workflows share these input patterns where applicable:

| Input | Used by | Meaning |
| --- | --- | --- |
| `version` | image, component, and player builds | Image/package version to produce. |
| `environment` | image, package, and repo workflows | GitHub environment, usually `Development` or `Production`. |
| `pacman_snapshot` | image, package, and repo workflows | Arch repository snapshot. Current choices are `2025/11/25`, `2025/05/31`, and `latest`. |
| `ffos_user_ref` | image and component workflows | `feral-file/ffos-user` branch, tag, or commit to checkout. |
| `ff_player_ref` | image and player workflows | `feral-file/ff-player` branch, tag, or commit to checkout. In `build-image-from-tags.yml`, this is optional and enables local player packaging only when supported by the selected FFOS ref. |
| `ffos_ref` | `build-image-from-tags.yml` | `feral-file/ffos` branch, tag, or commit used for a tag-based image build. |
| `component` | `manual-build-components.yaml` | Component package to build, such as `feral-controld`, `feral-setupd`, `feral-sys-monitord`, `feral-watchdog`, or `launcher-ui`. |
| `soak-test` | image workflows | Include soak test user data and packages. |
| `dev_iso` | image workflows | Add development tools and source metadata to the ISO. |
| `enable_local_hub` | image workflows | Set local hub support in generated runtime config. |
| `update_min_version` | image upload workflows | Update `min_runtime_version` in `version-info.json`. |
| `update_required_version` | image upload workflows | Update `min_upgradeable_version` in `version-info.json`. |
| `update_recovery_version` | image upload workflows | Update `recovery_version` in `version-info.json`. |

## Build Outputs

Uploaded artifacts use the current GitHub ref name as the R2 channel:

```text
{branch}/
|-- os/x86_64/
|   |-- feral-controld-{version}-x86_64.pkg.tar.zst
|   |-- feral-setupd-{version}-x86_64.pkg.tar.zst
|   |-- feral-sys-monitord-{version}-x86_64.pkg.tar.zst
|   |-- feral-watchdog-{version}-x86_64.pkg.tar.zst
|   |-- feral-player-{version}-x86_64.pkg.tar.zst
|   |-- feralfile.db.tar.gz
|   `-- feralfile.files.tar.gz
|-- FF1-{channel}-{version}.iso
|-- FF1-{channel}-{version}.iso.sig
`-- version-info.json
```

## Required Secrets and Variables

Build and upload workflows require repository secrets and variables. `make verify` and `verify.yml` do not.

Common required secrets:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_ACCESS_KEY_ID`
- `CLOUDFLARE_SECRET_ACCESS_KEY`
- `REPO_ACCESS_TOKEN`
- `AWS_KMS_FF1_RELEASE_SIGNER_ROLE_ARN`
- `AWS_KMS_FF1_RELEASE_SIGNING_KEY_ID`

Additional image/player configuration may use:

- `SENTRY_AUTH_TOKEN`
- `SENTRY_ORG`
- `SENTRY_DSN_PLAYER`
- `SENTRY_DSN_CONTROLD`
- `SENTRY_DSN_WATCHDOG`
- `SENTRY_DSN_SYS_MONITORD`
- `RELAYER_API_KEY`
- `HEARTBEAT_ENDPOINT`
- `VMAGENT_REMOTE_URL`
- `VMAGENT_REMOTE_BEARER_TOKEN`
- `OPENPANEL_CLIENT_ID`
- `OPENPANEL_CLIENT_ID_TEST`
- `OPENPANEL_CLIENT_SECRET`
- `OPENPANEL_CLIENT_SECRET_TEST`

Common variables:

- `CLOUDFLARE_R2_BUCKET_NAME`
- `PUB_DOC_URL`
- `RELAYER_ENDPOINT`

# FFOS - Arch Linux ISO Build Repository

## Architecture Overview

FFOS is the centralized build repository responsible for creating FFOS images. It orchestrates the entire build process by coordinating with the ffos-user repository for components and user data.

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   ffos-user     │    │      ffos       │    │   R2 Storage    │
│   Repository    │    │   Repository    │    │                 │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ components/ │ │    │ │   GitHub    │ │    │ │ {branch}/   │ │
│ │ users/      │ │    │ │  Actions    │ │    │ │ os/x86_64/  │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ │ *.iso       │ │
│                 │    │                 │    │ └─────────────┘ │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       ▲
         │                       │                       │
         │                       │                       │
         ▼                       ▼                       │
   Component Code         Build Process           Upload Results
   User Data             ISO Generation
```

## Repository Structure

```
ffos/
├── .github/workflows/           # GitHub Actions workflows
│   ├── build-components.yaml    # Individual component build
│   ├── pacman-repo.yaml        # Pacman repository management
│   ├── build-image-to-cf.yml   # Complete build pipeline
│   └── pure-build-image-to-cf.yml # Pure ISO build
├── archiso-ff1/           # Archiso configuration
│   ├── airootfs/               # Root filesystem template
│   ├── efiboot/                # EFI boot configuration
│   ├── packages.x86_64         # Package list
│   └── profiledef.sh           # Profile definition
└── README.md                   # This file
```

## Workflow Architecture

### 1. Component Build Layer (`build-components.yaml`)

**Purpose**: Build individual components from ffos-user repository

**Inputs**:
- `component`: Component name (feral-controld, feral-setupd, etc.)
- `version`: Package version
- `ffos_user_ref`: ffos-user repository reference
- `environment`: Build environment (Development/Production)

**Process**:
1. Checkout ffos-user repository using specified reference
2. Determine build type (Go/Rust) based on component
3. Create pacman package with PKGBUILD
4. Upload package to R2 storage

**Output**: Pacman package uploaded to `{branch}/os/x86_64/`

### 2. Repository Management Layer (`pacman-repo.yaml`)

**Purpose**: Manage pacman repository database

**Process**:
1. Download all packages from R2
2. Generate repository database
3. Clean old packages
4. Upload updated database

**Output**: Updated `feralfile.db.tar.gz` and `feralfile.files.tar.gz`

### 3. ISO Build Layer (`build-image-to-cf.yml`)

**Purpose**: Complete ISO build pipeline

**Workflow**:
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Build All      │    │  Update Pacman  │    │  Build ISO      │
│  Components     │───▶│   Repository    │───▶│   Image         │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         ▼                       ▼                       ▼
   Upload Packages         Generate DB           Upload ISO
   to R2 Storage          Clean Old Pkgs        to R2 Storage
```

**Steps**:
1. **Component Build Phase**: Build all components in parallel
2. **Repository Update Phase**: Update pacman repository
3. **ISO Generation Phase**: 
   - Copy archiso profile
   - Merge user data from ffos-user
   - Configure pacman repositories
   - Build ISO image
   - Upload to R2

### 4. Pure Build Layer (`pure-build-image-to-cf.yml`)

**Purpose**: Fast ISO build without component building

**Use Case**: When components already exist in R2 storage

**Process**:
1. Skip component building
2. Directly build ISO with existing components
3. Upload ISO to R2

## Data Flow Architecture

### Component Data Flow
```
ffos-user/components/ → ffos build process → R2/{branch}/os/x86_64/
```

### User Data Flow
```
ffos-user/users/ → ISO airootfs/home/ → Final ISO
```

### Configuration Flow
```
ffos-user/users/feralfile/.config/ → ISO /home/feralfile/.config/
ffos-user/users/soaktest/ → ISO /home/soaktest/ (conditional)
```

## Build Configuration

### Environment Variables
- `CLOUDFLARE_ACCOUNT_ID`: Cloudflare account identifier
- `CLOUDFLARE_ACCESS_KEY_ID`: R2 access key
- `CLOUDFLARE_SECRET_ACCESS_KEY`: R2 secret key
- `REPO_ACCESS_TOKEN`: GitHub token for ffos-user access

### Build Parameters
- `version`: ISO version number
- `ffos_user_ref`: ffos-user repository reference
- `soak-test`: Include soak test components
- `environment`: Development/Production environment
- `is_development`: Include development tools
- `install_to_emmc`: Build installation image

## R2 Storage Structure

```
{branch}/
├── os/x86_64/
│   ├── feral-controld-{version}-x86_64.pkg.tar.zst
│   ├── feral-setupd-{version}-x86_64.pkg.tar.zst
│   ├── feral-sys-monitord-{version}-x86_64.pkg.tar.zst
│   ├── feral-watchdog-{version}-x86_64.pkg.tar.zst
│   ├── feralfile.db.tar.gz
│   └── feralfile.files.tar.gz
├── FF1-{develop|release|demo|other}-{version}.iso
└── release_notes_{version}.md
```

## Local Verification

Run the same non-mutating repository verification path used by CI:

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
| `build-image-to-cf.yml` | `workflow_dispatch` | Full FFOS image pipeline: build component packages, update the pacman repo DB, build/sign/upload the ISO, and update version metadata. |
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

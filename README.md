# Kamal Accessories Updater

[![Test](https://github.com/robfrank/kamal-accessories-updater/actions/workflows/test.yml/badge.svg)](https://github.com/robfrank/kamal-accessories-updater/actions/workflows/test.yml)
[![Release](https://github.com/robfrank/kamal-accessories-updater/actions/workflows/release.yml/badge.svg)](https://github.com/robfrank/kamal-accessories-updater/actions/workflows/release.yml)

A GitHub Action that automatically checks for and updates [Kamal](https://kamal-deploy.org/) accessories to their latest versions from Docker Hub, GitHub Container Registry (GHCR), and other OCI registries.

## Features

- 🔍 **Automatic Version Detection** - Scans your Kamal deployment configurations for accessories and checks registries for latest versions
- 🌐 **Multi-Registry Support** - Works with Docker Hub, GitHub Container Registry (ghcr.io), and other OCI-compliant registries
- 📦 **Semantic Versioning** - Intelligently compares semantic versions to ensure only newer versions are applied
- 🔒 **SHA256 Support** - Automatically fetches and includes SHA256 digests for enhanced security
- 📝 **Pull Request Creation** - Optionally creates pull requests with detailed update information
- ⚡ **Caching** - Caches Docker Hub API responses to improve performance and reduce API calls
- 🎯 **Multiple Modes** - Check-only, interactive update, or automatic update modes

## Quick Start

Add this action to your workflow to automatically check for accessory updates:

```yaml
name: Update Kamal Accessories

on:
  workflow_dispatch:
  schedule:
    - cron: "0 8 * * 0"  # Every Sunday at 8 AM UTC

jobs:
  update:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4

      - name: Update Kamal accessories
        uses: robfrank/kamal-accessories-updater@v1
        with:
          config-dir: config
          mode: update-all
          create-pr: true
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `config-dir` | Directory containing Kamal `deploy*.yml` files | No | `config` |
| `mode` | Update mode: `check`, `update`, or `update-all` | No | `update-all` |
| `create-pr` | Whether to create a pull request with updates | No | `true` |
| `pr-branch` | Branch name for the pull request | No | `update/kamal-accessories` |
| `pr-title` | Title for the pull request | No | `chore: bump Kamal accessories versions` |
| `pr-body` | Body text for the pull request | No | See action.yml |
| `pr-labels` | Comma-separated list of labels for the PR | No | `dependencies` |
| `github-token` | GitHub token for creating pull requests | No | `${{ github.token }}` |

### Mode Options

- **`check`** - Only check for updates, don't modify files
- **`update`** - Update files but prompt for confirmation (not applicable in CI)
- **`update-all`** - Automatically update all accessories to latest versions

## Outputs

| Output | Description |
|--------|-------------|
| `updates-available` | Whether any updates are available (`true`/`false`) |
| `updates-count` | Number of updates available |
| `updates-json` | JSON array of all updates |
| `pr-number` | Pull request number if created |
| `pr-url` | Pull request URL if created |

## Usage Examples

### Basic Usage

Check for updates and create a PR:

```yaml
- name: Update accessories
  uses: robfrank/kamal-accessories-updater@v1
  with:
    config-dir: config
```

### Check Only (No Updates)

```yaml
- name: Check for updates
  id: check
  uses: robfrank/kamal-accessories-updater@v1
  with:
    config-dir: config
    mode: check
    create-pr: false

- name: Comment on PR
  if: steps.check.outputs.updates-available == 'true'
  run: |
    echo "Found ${{ steps.check.outputs.updates-count }} update(s)"
    echo "${{ steps.check.outputs.updates-json }}"
```

### Update Without PR

```yaml
- name: Update accessories
  uses: robfrank/kamal-accessories-updater@v1
  with:
    config-dir: config
    mode: update-all
    create-pr: false

- name: Commit changes
  run: |
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add .
    git commit -m "chore: update Kamal accessories"
    git push
```

### Custom PR Configuration

```yaml
- name: Update accessories
  uses: robfrank/kamal-accessories-updater@v1
  with:
    config-dir: config
    pr-branch: dependencies/kamal-accessories
    pr-title: "⬆️ Update Kamal accessories to latest versions"
    pr-labels: "dependencies,automation,kamal"
```

## How It Works

1. **Scans Configuration Files** - Finds all `deploy*.yml` files in your config directory
2. **Extracts Accessories** - Parses YAML to identify accessories and their current versions
3. **Detects Registry** - Automatically detects the registry (Docker Hub, GHCR, etc.) from the image name
4. **Queries Registry API** - Fetches latest semantic versions from the appropriate registry
5. **Compares Versions** - Intelligently compares versions to determine if updates are available
6. **Fetches Digests** - Retrieves SHA256 digests for the latest versions
7. **Updates Files** - Modifies your configuration files with new versions and digests
8. **Creates PR** - Optionally creates a pull request with the changes

## Supported Accessories

This action works with any Docker image used as a Kamal accessory. Common examples include:

- Redis (`redis`)
- PostgreSQL (`postgres`)
- MySQL (`mysql`)
- Memcached (`memcached`)
- BusyBox (`busybox`)
- Any custom Docker image on Docker Hub

## Supported Registries

The action supports multiple container registries:

### Docker Hub (docker.io)

**Default registry** - No authentication required for public images.

```yaml
accessories:
  redis:
    image: redis:7.0.0                    # Official image (implicit docker.io)

  custom:
    image: myorg/myapp:1.0.0             # Organization image

  explicit:
    image: docker.io/library/postgres:15 # Explicit registry prefix
```

### GitHub Container Registry (ghcr.io)

**Requires authentication** for most operations. Set the `GHCR_TOKEN` environment variable with a GitHub Personal Access Token (PAT) or use the automatic `GITHUB_TOKEN`.

```yaml
accessories:
  myapp:
    image: ghcr.io/myorg/myapp:1.0.0

  public:
    image: ghcr.io/owner/public-image:2.0.0
```

**GitHub Action Configuration for GHCR:**

```yaml
- name: Update accessories
  uses: robfrank/kamal-accessories-updater@v1
  with:
    config-dir: config
  env:
    GHCR_TOKEN: ${{ secrets.GITHUB_TOKEN }}  # Use GitHub token for GHCR access
```

**For private GHCR images**, create a GitHub PAT with `read:packages` scope:

```yaml
env:
  GHCR_TOKEN: ${{ secrets.GHCR_PAT }}  # Use custom PAT for private images
```

### Other Registries

The action includes detection for:
- **Google Container Registry** (gcr.io)
- **Quay.io** (quay.io)
- **Generic OCI registries** (basic support)

Support for additional registries is being actively developed. Open an issue if you need support for a specific registry.

## Configuration File Format

Your Kamal configuration files should follow the standard format:

```yaml
accessories:
  # Docker Hub - official image (default registry)
  redis:
    image: redis:7.0.0
    host: 192.168.0.1
    # ... other configuration

  # Docker Hub - with SHA256 digest
  postgres:
    image: postgres:15.0@sha256:abc123...
    host: 192.168.0.1
    # ... other configuration

  # GitHub Container Registry
  myapp:
    image: ghcr.io/myorg/myapp:1.2.3@sha256:def456...
    host: 192.168.0.1
    # ... other configuration

  # Docker Hub - organization image
  custom:
    image: mycompany/myservice:2.0.0
    host: 192.168.0.1
    # ... other configuration
```

The action will:
- Automatically detect the registry from the image name
- Preserve your existing configuration structure
- Update only the image version
- Add or update SHA256 digests
- Keep all other settings intact

## Caching

The action caches registry API responses for 1 hour to:
- Reduce API calls
- Improve performance
- Avoid rate limiting

Cache is stored in `/tmp/docker-registry-cache` and automatically cleaned up. Each registry is cached separately to ensure accuracy.

## Testing

Run the test suite locally:

```bash
# Run all tests
./test/run-tests.sh

# Run unit tests only
./test/test-utils.sh

# Run integration tests only
./test/test-integration.sh
```

## Development

### Project Structure

```
.
├── action.yml                    # Action metadata
├── src/
│   ├── check-updates.sh         # Main update logic
│   └── utils.sh                 # Utility functions
├── test/
│   ├── fixtures/                # Test configurations
│   ├── test-utils.sh           # Unit tests
│   ├── test-integration.sh     # Integration tests
│   └── run-tests.sh            # Test runner
└── .github/
    └── workflows/
        ├── test.yml            # CI workflow
        ├── release.yml         # Release workflow
        └── upgrade-accessories-versions.yml  # Example workflow
```

### Running Locally

You can test the action locally with your own configuration:

```bash
# Check for updates only
./src/check-updates.sh path/to/config check

# Update all accessories
./src/check-updates.sh path/to/config update-all
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for your changes
4. Ensure all tests pass
5. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Related Resources

- [Kamal Documentation](https://kamal-deploy.org/)
- [Kamal Accessories Guide](https://kamal-deploy.org/docs/configuration/accessories/)
- [Docker Hub API](https://docs.docker.com/registry/spec/api/)
- [GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec)

## Acknowledgments

- Built for use with [Kamal](https://kamal-deploy.org/) by 37signals
- Uses [peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request) for PR creation

## Support

If you encounter any issues or have questions:

- [Open an issue](https://github.com/robfrank/kamal-accessories-updater/issues)
- [View documentation](https://github.com/robfrank/kamal-accessories-updater)
- [Check examples](.github/workflows/upgrade-accessories-versions.yml)

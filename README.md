# mac-bootstrap

A deliberately small, public-safe Stage 1 bootstrap for a new Apple-silicon Mac.
It installs Xcode Command Line Tools, GitHub CLI, and OpenCode, uses interactive GitHub browser authentication
to download the private `sjvreddy/dotfiles` archive, and installs its minimal
OpenCode control plane.

## Security boundary

This repository must remain public-safe. It contains **no** secrets, SSH keys,
OAuth client secrets, recovery images, private configuration, or tokens. The
private dotfiles repository is downloaded only after the user completes GitHub
OAuth in the browser.

The script verifies the SHA-256 checksum published alongside the GitHub CLI
release. OpenCode is installed through its official installer.

## Use on a new Mac

Download the current `main` script, inspect it, then run it:

```bash
mkdir -p ~/Downloads/new-mac-bootstrap
curl -fL -o ~/Downloads/new-mac-bootstrap/bootstrap-opencode.sh \
  https://raw.githubusercontent.com/sjvreddy/mac-bootstrap/main/bootstrap-opencode.sh
less ~/Downloads/new-mac-bootstrap/bootstrap-opencode.sh
chmod +x ~/Downloads/new-mac-bootstrap/bootstrap-opencode.sh
~/Downloads/new-mac-bootstrap/bootstrap-opencode.sh
```

Review and publish changes to `main` before using this recovery path.

## Maintenance

The source of truth for `bootstrap-opencode.sh` is currently maintained in the
private `sjvreddy/dotfiles` repository at `scripts/bootstrap-opencode.sh`. When
changing it, publish the reviewed identical file here before using the
bootstrap on a new Mac.

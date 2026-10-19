#!/usr/bin/env bash
# Public-safe Stage 1 bootstrap for a clean Apple-silicon Mac.
# It installs only GitHub CLI, OpenCode, and the private dotfiles control plane.
# No credentials are embedded; GitHub access is granted interactively in-browser.

set -euo pipefail

REPOSITORY="${DOTFILES_REPOSITORY:-sjvreddy/dotfiles}"
BRANCH="${DOTFILES_BRANCH:-main}"
BOOTSTRAP_ROOT="${BOOTSTRAP_ROOT:-$HOME/.cache/new-mac-bootstrap}"
LOCAL_BIN="$HOME/.local/bin"

info() { printf '[✓] %s\n' "$1"; }
note() { printf '[~] %s\n' "$1"; }
fail() { printf '[✗] %s\n' "$1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "This bootstrap supports macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "This bootstrap currently supports Apple-silicon Macs only."

mkdir -p "$BOOTSTRAP_ROOT" "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

install_temporary_path() {
    local zprofile="$HOME/.zprofile"
    local begin='# >>> new-mac-bootstrap PATH >>>'
    local end='# <<< new-mac-bootstrap PATH <<<'

    if [[ -f "$zprofile" ]] && ! grep -qF "$begin" "$zprofile"; then
        fail "Refusing to modify existing ~/.zprofile during bootstrap. Add ~/.local/bin and ~/.opencode/bin to PATH manually."
    fi

    if [[ ! -f "$zprofile" ]]; then
        cat > "$zprofile" <<EOF
$begin
export PATH="$HOME/.opencode/bin:$LOCAL_BIN:\$PATH"
$end
EOF
        info "Added temporary OpenCode and GitHub CLI PATH to ~/.zprofile"
    fi
}

install_command_line_tools() {
    if xcode-select -p >/dev/null 2>&1; then
        info "Xcode Command Line Tools already available"
        return
    fi

    note "Requesting Xcode Command Line Tools (required for GitHub CLI authentication)..."
    # macOS displays its own installation progress. This command returns before
    # installation completes, so wait rather than letting the bootstrap fail
    # later when GitHub CLI configures Git credentials.
    xcode-select --install >/dev/null 2>&1 || true
    local wait_cycles=0
    until xcode-select -p >/dev/null 2>&1; do
        wait_cycles=$((wait_cycles + 1))
        if (( wait_cycles % 6 == 0 )); then
            note "Still waiting for Xcode Command Line Tools to finish..."
        fi
        sleep 5
    done
    info "Xcode Command Line Tools installed"
}

install_gh() {
    if command -v gh >/dev/null 2>&1; then
        info "GitHub CLI already available: $(command -v gh)"
        return
    fi

    note "Downloading the current official GitHub CLI release..."
    local release_url version archive checksums expected actual extracted
    release_url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest)"
    version="${release_url##*/v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Could not determine the GitHub CLI version."

    archive="$BOOTSTRAP_ROOT/gh_${version}_macOS_arm64.zip"
    checksums="$BOOTSTRAP_ROOT/gh_${version}_checksums.txt"
    curl -fL --retry 3 -o "$archive" "https://github.com/cli/cli/releases/download/v${version}/gh_${version}_macOS_arm64.zip"
    curl -fL --retry 3 -o "$checksums" "https://github.com/cli/cli/releases/download/v${version}/gh_${version}_checksums.txt"
    expected="$(awk -v file="gh_${version}_macOS_arm64.zip" '$2 == file { print $1 }' "$checksums")"
    actual="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
    [[ -n "$expected" && "$actual" == "$expected" ]] || fail "GitHub CLI checksum verification failed."

    extracted="$BOOTSTRAP_ROOT/gh_${version}_macOS_arm64"
    rm -rf "$extracted"
    ditto -x -k "$archive" "$BOOTSTRAP_ROOT"
    [[ -x "$extracted/bin/gh" ]] || fail "GitHub CLI archive did not contain the expected binary."
    ln -sfn "$extracted/bin/gh" "$LOCAL_BIN/gh"
    info "Installed GitHub CLI $version"
}

install_opencode() {
    if command -v opencode >/dev/null 2>&1; then
        info "OpenCode already available: $(command -v opencode)"
        return
    fi

    note "Installing OpenCode from its official installer..."
    curl -fsSL https://opencode.ai/v2/install | bash
    export PATH="$HOME/.opencode/bin:$LOCAL_BIN:$PATH"
    command -v opencode >/dev/null 2>&1 || fail "OpenCode installed but is not on PATH. Add ~/.opencode/bin to PATH and re-run."
    info "Installed OpenCode"
}

download_dotfiles() {
    local archive checkout top_level
    archive="$BOOTSTRAP_ROOT/dotfiles.tar.gz"
    checkout="$BOOTSTRAP_ROOT/dotfiles"

    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
        note "Opening the GitHub browser-authentication flow..."
        gh auth login --hostname github.com --git-protocol https --web --scopes repo
    fi

    rm -f "$archive"
    rm -rf "$checkout"
    gh api "/repos/$REPOSITORY/tarball/$BRANCH" > "$archive"
    mkdir -p "$checkout"
    tar -xzf "$archive" -C "$checkout" --strip-components=1
    [[ -x "$checkout/scripts/control-plane.sh" ]] || fail "Downloaded dotfiles archive is missing scripts/control-plane.sh."
    info "Downloaded private dotfiles archive to $checkout"
    DOTFILES_DIR="$checkout"
}

install_temporary_path
install_command_line_tools
install_gh
install_opencode
DOTFILES_DIR=""
download_dotfiles
bash "$DOTFILES_DIR/scripts/control-plane.sh"

printf '\nLaunch OpenCode now? [Y/n] '
read -r answer
if [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; then
    exec opencode "$DOTFILES_DIR"
fi

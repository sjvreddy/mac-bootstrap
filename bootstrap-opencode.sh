#!/usr/bin/env bash
# Public-safe Stage 1 bootstrap for a clean Apple-silicon Mac.
# It installs Command Line Tools, Chrome, GitHub CLI, OpenCode, and the private
# dotfiles control plane.
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

    note "Finding the Xcode Command Line Tools update..."
    # This marker makes the on-demand CLT package visible to softwareupdate on
    # clean Macs. Unlike `xcode-select --install`, softwareupdate prints actual
    # download and installation progress to this terminal.
    local clt_marker="$BOOTSTRAP_ROOT/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    local clt_label
    touch "$clt_marker"
    clt_label="$( (softwareupdate --list 2>&1 || true) \
        | sed -n 's/^[[:space:]]*\* Label: \(Command Line Tools.*\)$/\1/p' \
        | head -n 1)"
    rm -f "$clt_marker"

    if [[ -n "$clt_label" ]]; then
        note "Installing $clt_label (macOS may request your administrator password)..."
        sudo softwareupdate --install "$clt_label" --verbose
    else
        # A macOS catalog can occasionally omit the label. Use the supported
        # fallback and wait rather than allowing the bootstrap to fail later.
        note "macOS did not expose a Command Line Tools update; requesting it through xcode-select..."
        xcode-select --install >/dev/null 2>&1 || true
    fi

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

install_chrome() {
    local chrome_app="/Applications/Google Chrome.app"
    if [[ -d "$chrome_app" ]]; then
        info "Google Chrome already available"
        return
    fi

    note "Google Chrome is not managed on this Mac; installing it before browser authentication..."
    local chrome_dmg="$BOOTSTRAP_ROOT/googlechrome.dmg"
    local chrome_volume
    curl -fL --retry 3 -o "$chrome_dmg" \
        "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
    chrome_volume="$(hdiutil attach -nobrowse -readonly "$chrome_dmg" \
        | sed -n 's/^.*\t\(\/Volumes\/.*\)$/\1/p' \
        | head -n 1)"
    [[ -n "$chrome_volume" && -d "$chrome_volume/Google Chrome.app" ]] \
        || fail "The Google Chrome disk image did not mount as expected."

    sudo ditto "$chrome_volume/Google Chrome.app" "$chrome_app"
    hdiutil detach "$chrome_volume" >/dev/null
    codesign --verify --deep --strict "$chrome_app" \
        || fail "Google Chrome signature verification failed."
    info "Installed Google Chrome"
}

set_chrome_as_default_browser() {
    local chrome_app="/Applications/Google Chrome.app"
    [[ -d "$chrome_app" ]] || fail "Google Chrome is not installed."

    # Register Chrome before changing LaunchServices handlers. Jamf installs can
    # complete immediately before this script starts, before registration occurs.
    local lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    [[ -x "$lsregister" ]] && "$lsregister" -f "$chrome_app" >/dev/null

    # Avoid compiling a LaunchServices helper: fresh macOS releases can ship a
    # Command Line Tools SDK before its linker fully supports that SDK's slices.
    # These are the same user LaunchServices handlers that macOS consults for
    # HTTP, HTTPS, and HTML documents.
    defaults write com.apple.LaunchServices/com.apple.launchservices.secure \
        LSHandlers -array-add '{LSHandlerURLScheme = http; LSHandlerRoleAll = "com.google.Chrome";}'
    defaults write com.apple.LaunchServices/com.apple.launchservices.secure \
        LSHandlers -array-add '{LSHandlerURLScheme = https; LSHandlerRoleAll = "com.google.Chrome";}'
    defaults write com.apple.LaunchServices/com.apple.launchservices.secure \
        LSHandlers -array-add '{LSHandlerContentType = "public.html"; LSHandlerRoleAll = "com.google.Chrome";}'

    # Explicitly direct GitHub CLI to Chrome in addition to setting macOS's
    # global default, so this bootstrap never falls back to Safari.
    export GH_BROWSER='open -a "Google Chrome"'
    export BROWSER="$GH_BROWSER"
    info "Set Google Chrome as the default browser"
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
install_chrome
set_chrome_as_default_browser
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

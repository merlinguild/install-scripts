#!/usr/bin/env bash

set -Eeuo pipefail

CLIENT_ID='Ov23lixRFRinB9oFrXw1'
ORG='merlinguild'
TEAM='members'
ARTIFACTS_REPO='merlinguild/artifacts'
SCOPES='read:org repo'
USER_AGENT='merlinguild-installer'
TOKEN_DIR="$HOME/.merlinguild"
TOKEN_PATH="$TOKEN_DIR/token"

LOCAL_PATH="${MG_LOCAL_PATH:-}"
LOCAL_URL="${MG_LOCAL_URL:-}"
TOKEN="${MG_TOKEN:-}"
REQUIRE_SIGNATURE=0
SKIP_SIGNATURE_CHECK=0

if [[ -t 1 ]]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_MAGENTA=$'\033[35m'; C_RESET=$'\033[0m'
else
  C_CYAN=; C_GREEN=; C_YELLOW=; C_RED=; C_MAGENTA=; C_RESET=
fi

info()   { printf '%s[info] %s%s\n'   "$C_CYAN"    "$*" "$C_RESET"; }
ok()     { printf '%s[ok]   %s%s\n'   "$C_GREEN"   "$*" "$C_RESET"; }
warn()   { printf '%s[warn] %s%s\n'   "$C_YELLOW"  "$*" "$C_RESET" >&2; }
fail()   { printf '%s[error]%s %s\n'  "$C_RED"     "$C_RESET" "$*" >&2; }
banner() {
  local msg="$*" line
  line=$(printf '=%.0s' $(seq 1 $((${#msg} + 4))))
  printf '\n%s%s%s\n'   "$C_MAGENTA" "$line"       "$C_RESET"
  printf '%s  %s  %s\n' "$C_MAGENTA" "$msg"        "$C_RESET"
  printf '%s%s%s\n\n'   "$C_MAGENTA" "$line"       "$C_RESET"
}

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Options:
  --local-path <file>     Install a local bundle (.dmg / .AppImage).
                          Overrides every other mode.
  --local-url <url>       Download a bundle from any URL and install.
  --token <ghp_...>       Pre-obtained GitHub OAuth token.
  --require-signature     Fail if a .sig sidecar is missing (local-file mode).
  --skip-signature-check  Allow install without .sig (direct-url mode).
  -h | --help             Show this message.

Environment (equivalents of the flags):
  MG_LOCAL_PATH, MG_LOCAL_URL, MG_TOKEN
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-path)          LOCAL_PATH="${2:?path required}"; shift 2 ;;
    --local-url)           LOCAL_URL="${2:?url required}"; shift 2 ;;
    --token)               TOKEN="${2:?token required}"; shift 2 ;;
    --require-signature)   REQUIRE_SIGNATURE=1; shift ;;
    --skip-signature-check) SKIP_SIGNATURE_CHECK=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) fail "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

detect_platform() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Darwin)
      case "$arch" in
        arm64|aarch64) echo 'darwin-aarch64' ;;
        x86_64)        echo 'darwin-x64' ;;
        *) fail "Unsupported macOS architecture: $arch"; exit 1 ;;
      esac ;;
    Linux)
      case "$arch" in
        x86_64) echo 'linux-x64' ;;
        aarch64|arm64) echo 'linux-aarch64' ;;
        *) fail "Unsupported Linux architecture: $arch"; exit 1 ;;
      esac ;;
    *) fail "Unsupported OS: $os (use install.ps1 on Windows)"; exit 1 ;;
  esac
}

asset_pattern_for() {
  case "$1" in
    darwin-aarch64) echo '*aarch64*.dmg' ;;
    darwin-x64)     echo '*x64*.dmg' ;;
    linux-x64)      echo '*amd64*.AppImage *x86_64*.AppImage' ;;
    linux-aarch64)  echo '*aarch64*.AppImage *arm64*.AppImage' ;;
  esac
}

gh_get() {
  local token="$1" url="$2"
  curl -fsSL \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H "User-Agent: $USER_AGENT" \
    "$url"
}

request_device_code() {
  curl -fsSL -X POST 'https://github.com/login/device/code' \
    -H 'Accept: application/json' \
    -H "User-Agent: $USER_AGENT" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "scope=$SCOPES"
}

poll_for_token() {
  local device_code="$1" interval="$2" expires_in="$3"
  local delay=$interval deadline response err
  deadline=$(( $(date +%s) + expires_in ))
  while [[ $(date +%s) -lt $deadline ]]; do
    sleep "$delay"
    response=$(curl -fsSL -X POST 'https://github.com/login/oauth/access_token' \
      -H 'Accept: application/json' \
      -H "User-Agent: $USER_AGENT" \
      --data-urlencode "client_id=$CLIENT_ID" \
      --data-urlencode "device_code=$device_code" \
      --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:device_code')
    if echo "$response" | grep -q '"access_token"'; then
      echo "$response" | sed -n 's/.*"access_token":[[:space:]]*"\([^"]*\)".*/\1/p'
      return 0
    fi
    err=$(echo "$response" | sed -n 's/.*"error":[[:space:]]*"\([^"]*\)".*/\1/p')
    case "$err" in
      authorization_pending) : ;;
      slow_down)             delay=$((delay + 5)) ;;
      expired_token)         fail 'Device code expired. Re-run the installer.'; return 1 ;;
      access_denied)         fail 'Authorisation was denied in the browser.'; return 1 ;;
      *)                     fail "GitHub OAuth error: $err"; return 1 ;;
    esac
  done
  fail 'Timed out waiting for you to authorise in the browser.'
  return 1
}

get_github_token() {
  if [[ -n "$TOKEN" ]]; then
    info 'Using token from --token / $MG_TOKEN.'
    echo "$TOKEN"
    return 0
  fi
  local dc user_code verification_uri device_code interval expires_in
  dc=$(request_device_code)
  user_code=$(echo "$dc"        | sed -n 's/.*"user_code":[[:space:]]*"\([^"]*\)".*/\1/p')
  verification_uri=$(echo "$dc" | sed -n 's/.*"verification_uri":[[:space:]]*"\([^"]*\)".*/\1/p')
  device_code=$(echo "$dc"      | sed -n 's/.*"device_code":[[:space:]]*"\([^"]*\)".*/\1/p')
  interval=$(echo "$dc"         | sed -n 's/.*"interval":[[:space:]]*\([0-9]*\).*/\1/p')
  expires_in=$(echo "$dc"       | sed -n 's/.*"expires_in":[[:space:]]*\([0-9]*\).*/\1/p')

  printf '\n'
  printf '  1. Open  %s%s%s\n' "$C_YELLOW" "$verification_uri" "$C_RESET"
  printf '  2. Enter %s%s%s\n' "$C_YELLOW" "$user_code"        "$C_RESET"
  printf "  3. Authorise 'Merlin Guild Installer'.\n"
  printf '\n'
  info 'Waiting for authorisation...'
  poll_for_token "$device_code" "${interval:-5}" "${expires_in:-900}"
}

assert_membership() {
  local token="$1" login
  login=$(gh_get "$token" 'https://api.github.com/user' | sed -n 's/.*"login":[[:space:]]*"\([^"]*\)".*/\1/p')
  info "Authenticated as $login. Checking $ORG/$TEAM membership..."
  local membership
  if ! membership=$(gh_get "$token" "https://api.github.com/orgs/$ORG/teams/$TEAM/memberships/$login" 2>/dev/null); then
    fail "Not a member of $ORG/$TEAM. DM the admin to request access."
    return 1
  fi
  if ! echo "$membership" | grep -q '"state":[[:space:]]*"active"'; then
    fail "Membership is not active. Accept the GitHub invitation and re-run."
    return 1
  fi
  ok 'Active membership confirmed.'
}

filter_assets() {
  local json="$1" patterns="$2" name url match
  while read -r line; do
    name=$(echo "$line" | sed -n 's/.*"name":[[:space:]]*"\([^"]*\)".*/\1/p')
    url=$(echo  "$line" | sed -n 's/.*"url":[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ -z "$name" || -z "$url" ]] && continue
    match=0
    for pat in $patterns; do
      [[ "$name" == $pat ]] && { match=1; break; }
    done
    [[ $match -eq 1 ]] && printf '%s\t%s\n' "$name" "$url"
  done < <(echo "$json" | tr '{' '\n' | grep -E '"name"|"url"')
}

strip_quarantine() {
  command -v xattr >/dev/null 2>&1 || return 0
  xattr -dr com.apple.quarantine "$@" 2>/dev/null || true
}

install_bundle() {
  local bundle="$1" platform="$2"
  strip_quarantine "$bundle"
  case "$platform" in
    darwin-*)
      info 'Mounting DMG...'
      local mnt app target
      mnt=$(hdiutil attach -nobrowse -readonly "$bundle" | awk '/\/Volumes\// {print $NF}' | tail -1)
      app=$(find "$mnt" -maxdepth 2 -name '*.app' | head -1)
      [[ -z "$app" ]] && { fail 'No .app inside the DMG.'; hdiutil detach "$mnt" >/dev/null; return 1; }
      target="/Applications/$(basename "$app")"
      info "Copying $(basename "$app") to /Applications..."
      rm -rf "$target"
      cp -R "$app" /Applications/
      hdiutil detach "$mnt" >/dev/null
      strip_quarantine "$target"
      ok 'Installed to /Applications.'
      ;;
    linux-*)
      local dest_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
      local dest="$dest_dir/merlinguild.AppImage"
      mkdir -p "$dest_dir"
      install -m 0755 "$bundle" "$dest"
      ok "Installed to $dest"
      case ":$PATH:" in
        *":$dest_dir:"*) : ;;
        *) warn "$dest_dir is not in \$PATH. Add it to your shell rc to launch 'merlinguild.AppImage' from anywhere." ;;
      esac
      ;;
  esac
}

save_token() {
  local token="$1"
  mkdir -p "$TOKEN_DIR"
  umask_prev=$(umask)
  umask 077
  printf '%s' "$token" > "$TOKEN_PATH"
  umask "$umask_prev"
  chmod 600 "$TOKEN_PATH"
  ok "OAuth token saved to $TOKEN_PATH (owner-only)."
}

new_temp_file() {
  local suffix="$1"
  mktemp -t "mg-XXXXXXXX${suffix}"
}

mode_local_path() {
  banner 'LOCAL INSTALL MODE - skipping GitHub entitlement check'
  [[ -f "$LOCAL_PATH" ]] || { fail "Bundle not found: $LOCAL_PATH"; exit 1; }
  local sig="$LOCAL_PATH.sig"
  if [[ ! -f "$sig" ]]; then
    if [[ $REQUIRE_SIGNATURE -eq 1 ]]; then
      fail "Missing signature next to $LOCAL_PATH. Drop --require-signature to override."
      exit 1
    fi
    warn "No signature sidecar at $sig. Proceeding (dev convenience)."
  fi
  install_bundle "$LOCAL_PATH" "$(detect_platform)"
}

mode_local_url() {
  banner 'LOCAL INSTALL MODE - skipping GitHub entitlement check'
  local platform ext bundle sig
  platform=$(detect_platform)
  case "$platform" in
    darwin-*) ext='.dmg' ;;
    linux-*)  ext='.AppImage' ;;
  esac
  bundle=$(new_temp_file "$ext")
  sig="$bundle.sig"
  info "Downloading bundle from $LOCAL_URL ..."
  curl -fSL -o "$bundle" -H "User-Agent: $USER_AGENT" "$LOCAL_URL"

  if curl -fsSL -o /dev/null -I -H "User-Agent: $USER_AGENT" "$LOCAL_URL.sig" 2>/dev/null; then
    info 'Downloading signature...'
    curl -fSL -o "$sig" -H "User-Agent: $USER_AGENT" "$LOCAL_URL.sig"
  else
    if [[ $SKIP_SIGNATURE_CHECK -ne 1 ]]; then
      fail "No .sig sidecar at $LOCAL_URL.sig. Re-upload the signature, or pass --skip-signature-check."
      rm -f "$bundle"; exit 1
    fi
    warn 'No .sig sidecar. Proceeding because --skip-signature-check was passed.'
  fi
  install_bundle "$bundle" "$platform"
  rm -f "$bundle" "$sig"
}

mode_github() {
  banner 'Merlin Guild Installer'
  TOKEN=$(get_github_token) || exit 1
  assert_membership "$TOKEN" || exit 1

  local platform patterns release_json asset_line name url tag
  platform=$(detect_platform)
  patterns=$(asset_pattern_for "$platform")

  info 'Fetching latest release metadata...'
  release_json=$(gh_get "$TOKEN" "https://api.github.com/repos/$ARTIFACTS_REPO/releases/latest")
  tag=$(echo "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  asset_line=$(filter_assets "$release_json" "$patterns" | head -1)
  [[ -n "$asset_line" ]] || { fail "Release $tag has no asset matching: $patterns"; exit 1; }
  name=$(echo "$asset_line" | cut -f1)
  url=$(echo  "$asset_line" | cut -f2)
  info "Release $tag asset: $name"

  local ext bundle sig_url sig
  case "$platform" in
    darwin-*) ext='.dmg' ;;
    linux-*)  ext='.AppImage' ;;
  esac
  bundle=$(new_temp_file "$ext")
  sig="$bundle.sig"

  info 'Downloading bundle...'
  curl -fSL -o "$bundle" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/octet-stream' \
    -H "User-Agent: $USER_AGENT" \
    "$url"

  sig_url=$(filter_assets "$release_json" "$name.sig" | head -1 | cut -f2)
  if [[ -n "$sig_url" ]]; then
    info 'Downloading signature...'
    curl -fSL -o "$sig" \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Accept: application/octet-stream' \
      -H "User-Agent: $USER_AGENT" \
      "$sig_url"
  else
    warn "Release $tag is missing a .sig sidecar. Proceeding anyway."
  fi

  install_bundle "$bundle" "$platform"
  save_token "$TOKEN"
  rm -f "$bundle" "$sig"
}

main() {
  if [[ -n "$LOCAL_PATH" ]]; then
    mode_local_path
  elif [[ -n "$LOCAL_URL" ]]; then
    mode_local_url
  else
    mode_github
  fi
  printf '\n'
  ok 'Merlin Guild is ready. Launch it from /Applications or your application menu.'
  printf '\n'
}

trap 'fail "Installer aborted on line $LINENO."' ERR
main "$@"

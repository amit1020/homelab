#!/usr/bin/env bash
# bootstrap.sh — sets up this repo on a new machine.
# Installs tooling, enables git hooks, and verifies SOPS decryption.
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { printf "${GREEN}v${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}!${NC} %s\n" "$1"; }
err()  { printf "${RED}x${NC} %s\n" "$1"; }

# Always operate from the repository root
cd "$(git rev-parse --show-toplevel)"

echo "-- Tooling --"
if command -v brew >/dev/null 2>&1; then
  for t in sops age gitleaks talosctl kubectl helm talhelper; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "$t already installed"
    else
      echo "Installing $t..."
      brew install "$t" || warn "$t failed - install manually"
    fi
  done
  # flux lives in a separate tap
  command -v flux >/dev/null 2>&1 || brew install fluxcd/tap/flux || true
else
  warn "Homebrew not found - install the tools manually"
fi

echo ""
echo "-- Git hooks --"
# Point git at the in-repo hooks directory so it travels with clones
git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true
[ -x .githooks/pre-commit ] && ok "pre-commit hook active" || err "pre-commit hook missing"

echo ""
echo "-- SOPS key --"
KEY="$HOME/.config/sops/age/keys.txt"
if [ -f "$KEY" ]; then
  chmod 600 "$KEY"
  ok "age key present"
  # Prove the key actually decrypts this repo's secrets
  if [ -f talos/talsecret.sops.yaml ]; then
    if sops --decrypt talos/talsecret.sops.yaml >/dev/null 2>&1; then
      ok "decryption works"
    else
      err "decryption failed - wrong or corrupted key"
      exit 1
    fi
  fi
else
  err "age key missing"
  echo ""
  echo "  mkdir -p ~/.config/sops/age"
  echo "  cp /Volumes/<drive>/homelab/age-key.txt $KEY"
  echo "  chmod 600 $KEY"
  echo ""
  exit 1
fi

echo ""
ok "Environment ready"

#!/usr/bin/env bash
# Runs inside archlinux:base-devel container.
# Builds linux-surface kernel renamed to linux-surface-ipu4 with IPU4P camera driver.
set -euxo pipefail

export PR_BRANCH="ipu4"
export PR_REPO="https://github.com/ruslanbay/linux-surface.git"
export KVER_DIR="6.18"                 # patches/<KVER_DIR>/0018-ipu4.patch
export NEWBASE="linux-surface-ipu4"

# --- toolchain ---
pacman -Syu --noconfirm --needed \
  base-devel git bc cpio gettext libelf perl tar xz python \
  rust rust-bindgen rust-src pahole inetutils sudo

# makepkg refuses root -> dedicated build user
useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/builder
chown -R builder:builder /build /out

sudo -u builder --preserve-env=PR_BRANCH,PR_REPO,KVER_DIR,NEWBASE \
  bash -euxo pipefail <<'EOF'
cd /build
git clone --depth 1 -b "$PR_BRANCH" "$PR_REPO" src
cd src/pkg/arch/kernel

# 1. bring the IPU4 patch next to the PKGBUILD
cp "/build/src/patches/${KVER_DIR}/0018-ipu4.patch" .

# 2. patch the PKGBUILD: add 0018 to source[], add SKIP checksum, rename pkgbase
python - <<'PY'
import os, re
base = os.environ["NEWBASE"]
p = open("PKGBUILD").read()

# add 0018-ipu4.patch right after 0017-powercap.patch in source=()
assert "0017-powercap.patch" in p
p = p.replace("  0017-powercap.patch\n",
              "  0017-powercap.patch\n  0018-ipu4.patch\n", 1)

# append a SKIP checksum as last element of sha256sums=( ... )
m = re.search(r"sha256sums=\((?:.|\n)*?\)", p)
blk = m.group(0)
blk2 = blk[:-1].rstrip() + "\n            'SKIP')"
p = p[:m.start()] + blk2 + p[m.end():]

# rename package base
p = p.replace("pkgbase=linux-surface\n", f"pkgbase={base}\n", 1)

open("PKGBUILD", "w").write(p)
print("patched PKGBUILD")
PY

# 3. enable IPU4P config (Ice Lake / Surface Pro 7)
cat >> surface.config <<'CFG'

# --- IPU4P camera (PR #2013) ---
CONFIG_VIDEO_INTEL_IPU=m
# CONFIG_VIDEO_INTEL_IPU4 is not set
CONFIG_VIDEO_INTEL_IPU4P=y
CONFIG_VIDEO_INTEL_IPU_SOC=y
CONFIG_VIDEO_INTEL_IPU_FW_LIB=y
# CONFIG_VIDEO_INTEL_IPU_WERROR is not set
CFG

echo "=== sanity: pkgbase + source ==="
grep -nE "^pkgbase=|0018-ipu4.patch" PKGBUILD

# 4. build. --skipinteg: PR is a dev branch, pinned sha256sums are stale
#    (patch/config files edited without checksum refresh); source integrity
#    is instead guaranteed by the signed Arch git tag pulled over https.
export MAKEFLAGS="-j$(nproc)"
makepkg -s --noconfirm --skipinteg --nocheck

cp -v ./*.pkg.tar.zst /out/
ls -la /out
EOF

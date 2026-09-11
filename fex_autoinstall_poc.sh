#!/bin/bash

# Usage: wget https://raw.githubusercontent.com/MitchellAugustin/fex_autoinstall/refs/heads/main/fex_autoinstall_poc.sh && bash fex_autoinstall_poc.sh

# Exit immediately if a command exits with a non-zero status.
set -e

ORIG_DIR=$(pwd)

TEMP_DIR=$(mktemp -d)

cleanup() {
  cd "$ORIG_DIR"
  rm -rf "$TEMP_DIR" ${BUILD_DIR:+"$BUILD_DIR"}
  echo "Cleaned up temporary directory: $TEMP_DIR"
}

trap cleanup EXIT

# Numbered menu shown 5 entries at a time; echoes the chosen entry.
paged_select() {
  local prompt="$1"; shift
  local items=("$@")
  local total=${#items[@]} page_size=5 page=0
  while true; do
    local start=$((page * page_size)) end=$((page * page_size + page_size))
    [ $end -gt $total ] && end=$total
    echo "" >&2
    echo "$prompt" >&2
    for ((i = start; i < end; i++)); do
      local label="${items[$i]}"
      [ $i -eq 0 ] && label="$label (latest)"
      echo "  $((i - start + 1))) $label" >&2
    done
    local extra=""
    [ $end -lt $total ] && { echo "  n) Show next $page_size" >&2; extra="$extra, n"; }
    [ $page -gt 0 ] && { echo "  p) Show previous $page_size" >&2; extra="$extra, p"; }
    read -rp "Select [1-$((end - start))$extra] (default: 1): " sel
    sel=${sel:-1}
    case "$sel" in
      n|N) [ $end -lt $total ] && page=$((page + 1));;
      p|P) [ $page -gt 0 ] && page=$((page - 1));;
      *[!0-9]*) echo "Invalid selection." >&2;;
      *)
        if [ "$sel" -ge 1 ] && [ $((start + sel)) -le $end ]; then
          echo "${items[$((start + sel - 1))]}"
          return
        fi
        echo "Invalid selection." >&2;;
    esac
  done
}

# Builds a .deb of the given FEX tag using the current PPA's debian/ packaging,
# so the result matches the PPA build (clang-17, lld, LTO, thunks, TUNE_ARCH).
build_fex_from_source() {
  local tag="$1" tag_version="${1#FEX-}"
  local series
  series=$(. /etc/os-release && echo "$VERSION_CODENAME")

  echo "Looking up current PPA packaging for $FEX_PACKAGE ($series)..."
  local sources
  sources=$(curl -fsSL "https://launchpad.net/api/1.0/~fex-emu/+archive/ubuntu/fex?ws.op=getPublishedSources&source_name=$FEX_PACKAGE&status=Published")
  local sourcepub
  sourcepub=$(echo "$sources" | jq -r --arg s "$series" '[.entries[] | select(.distro_series_link | endswith("/" + $s))][0].self_link // empty')
  if [ -z "$sourcepub" ]; then
    echo "No $FEX_PACKAGE packaging published for '$series'; falling back to noble packaging."
    sourcepub=$(echo "$sources" | jq -r '[.entries[] | select(.distro_series_link | endswith("/noble"))][0].self_link')
  fi
  local debian_tar_url
  debian_tar_url=$(curl -fsSL "$sourcepub?ws.op=sourceFileUrls" | jq -r '.[] | select(endswith(".debian.tar.xz"))')

  # /var/tmp is disk-backed; a FEX build is several GB and would not fit a tmpfs /tmp.
  BUILD_DIR=$(mktemp -d /var/tmp/fex_build.XXXXXX)
  echo "Cloning FEX $tag into $BUILD_DIR..."
  git clone --depth 1 --branch "$tag" https://github.com/FEX-Emu/FEX.git "$BUILD_DIR/FEX"
  pushd "$BUILD_DIR/FEX" >/dev/null

  # Test-binary submodules are large and unused with BUILD_TESTING=False.
  local submodules
  submodules=$(git config --file .gitmodules --get-regexp path | awk '{print $2}' | grep -vE 'tests?-bins')
  git submodule update --init --depth 1 $submodules || git submodule update --init $submodules

  curl -fsSL "$debian_tar_url" | tar -xJ
  sed -i "s/-DOVERRIDE_VERSION=[^ ]*/-DOVERRIDE_VERSION=$tag_version/" debian/rules
  # Older tags gate unit tests behind BUILD_TESTS (default ON) rather than BUILD_TESTING.
  sed -i "s/-DBUILD_TESTING=False/-DBUILD_TESTING=False -DBUILD_TESTS=False/" debian/rules
  cat > debian/changelog <<EOF
$FEX_PACKAGE (${tag_version}~local1) $series; urgency=medium

  * Local build of FEX release $tag by fex_autoinstall.

 -- fex_autoinstall <fex_autoinstall@localhost>  $(date -R)
EOF

  echo "Installing FEX build dependencies..."
  sudo apt build-dep -y ./

  echo "Building FEX $tag (this takes a long time)..."
  dpkg-buildpackage -b -us -uc -j"$(nproc)"
  popd >/dev/null

  echo "Installing locally built $FEX_PACKAGE..."
  sudo apt install -y "$BUILD_DIR"/${FEX_PACKAGE}_*.deb
  # Keep apt from replacing the chosen release with the PPA's latest on upgrade.
  sudo apt-mark hold "$FEX_PACKAGE"
  echo "$FEX_PACKAGE is held at $tag; run 'sudo apt-mark unhold $FEX_PACKAGE' to allow PPA upgrades again."
}

nvidia_driver_version=$(cat /sys/module/nvidia/version 2>/dev/null || true)
if [ -z "$nvidia_driver_version" ]; then
  echo "---"
  echo " WARNING: Could not detect NVIDIA driver version."
  echo "   The NVIDIA NGX libraries (for DLSS support) will not be installed."
  echo "   All other components (FEX, Steam, etc.) can still be installed."
  echo "   (This is expected if you are running on a device without an Nvidia GPU)."
  echo "---"

  while true; do
      read -p "Continue? " yn
      case $yn in
          [Yy]* ) break;;
          [Nn]* ) exit 1;;
          * ) echo "y/n only";;
      esac
  done

  echo "Continuing installation..."
else
  echo "Found NVIDIA driver version: $nvidia_driver_version"
fi

cd "$TEMP_DIR"
echo "Working in temporary directory: $TEMP_DIR"

ARM_PLATFORM_VERSION=$(lscpu | grep -qE "dit|flagm2" && echo "armv8.4" || echo "armv8.2")
echo "Detected ARM platform version: $ARM_PLATFORM_VERSION"

FEX_PACKAGE="fex-emu-$ARM_PLATFORM_VERSION"

echo ""
echo "How would you like to install FEX?"
echo "  1) Latest release from the FEX-Emu PPA (recommended, prebuilt)"
echo "  2) Choose a specific FEX release and build it from source (slow: 30+ minutes, several GB of disk)"
while true; do
  read -rp "Select [1-2] (default: 1): " INSTALL_MODE
  INSTALL_MODE=${INSTALL_MODE:-1}
  case "$INSTALL_MODE" in
    1|2) break;;
    *) echo "Please enter 1 or 2.";;
  esac
done

echo "Adding FEX-Emu PPA..."
sudo add-apt-repository -y ppa:fex-emu/fex
sudo apt update

if [ "$INSTALL_MODE" = "1" ]; then
  echo "Installing FEX-Emu and Vulkan packages..."
  sudo apt install -y "$FEX_PACKAGE" fex-emu-wine patchelf mesa-vulkan-drivers jq
else
  echo "Installing build tooling and Vulkan packages..."
  sudo apt install -y git jq dpkg-dev debhelper fex-emu-wine patchelf mesa-vulkan-drivers

  echo "Fetching FEX release tags..."
  # Tags before FEX-2501 use a different tool layout/GUI toolkit than the current
  # PPA packaging expects and are not offered.
  mapfile -t FEX_TAGS < <(git ls-remote --tags https://github.com/FEX-Emu/FEX.git 'FEX-*' | grep -v '\^{}' | sed 's|.*refs/tags/||' | sort -rV | sed '/^FEX-2501$/q')
  FEX_TAG=$(paged_select "Which FEX release do you want to build?" "${FEX_TAGS[@]}")
  build_fex_from_source "$FEX_TAG"
fi

echo "Downloading required files..."
wget https://repo.steampowered.com/steam/archive/stable/steam-launcher_latest_all.deb
wget https://raw.githubusercontent.com/MitchellAugustin/fex_autoinstall/refs/heads/main/patch_steam_for_arm64.patch
wget https://raw.githubusercontent.com/MitchellAugustin/fex_autoinstall/refs/heads/main/fex_config_with_thunking_enabled.json

echo "Installing Steam from .deb..."
sudo apt install -y ./steam-launcher_latest_all.deb

echo "Fetching FEX RootFS..."
FEXRootFSFetcher -y -x

echo "Applying FEX config..."
mkdir -p ~/.fex-emu
mv fex_config_with_thunking_enabled.json ~/.fex-emu/Config.json
sed -i 's/Ubuntu_24_04.sqsh/Ubuntu_24_04/g' ~/.fex-emu/Config.json

echo "Configuring AppArmor..."
echo "abi <abi/4.0>,
include <tunables/global>
 
profile FEXBash /usr/bin/FEXBash flags=(unconfined) {
  userns,
 
  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/FEXBash>
}
" > FEXBash_apparmor.txt

echo "abi <abi/4.0>,
include <tunables/global>
 
profile steam /usr/bin/steam flags=(unconfined) {
  userns,
 
  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/steam>
}
" > steam_apparmor.txt

echo "abi <abi/4.0>,
include <tunables/global>
 
profile bwrap /{usr/,}/bin/bwrap flags=(unconfined) {
  userns,
 
  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/bwrap>
}
" > bwrap_apparmor.txt

sudo mv steam_apparmor.txt /etc/apparmor.d/steam
sudo mv FEXBash_apparmor.txt /etc/apparmor.d/FEXBash
sudo mv bwrap_apparmor.txt /etc/apparmor.d/bwrap

set +e
sudo apparmor_parser -Tr /etc/apparmor.d/steam
sudo apparmor_parser -Tr /etc/apparmor.d/FEXBash
sudo apparmor_parser -Tr /etc/apparmor.d/bwrap
set -e


if [ -n "$nvidia_driver_version" ]; then
    echo "Installing NVIDIA NGX libs..."
    nvidia_driver_version=$(cat /sys/module/nvidia/version)
    wget https://download.nvidia.com/XFree86/Linux-x86_64/$nvidia_driver_version/NVIDIA-Linux-x86_64-$nvidia_driver_version.run

    ubuntu=$(jq -r '.Config.RootFS' $HOME/.fex-emu/Config.json)
    rootfs="$HOME/.fex-emu/RootFS/$ubuntu"
     
    runfile=$(realpath ./NVIDIA-Linux-x86_64-$nvidia_driver_version.run)
    runfilename=$(basename $runfile)
     
    sh $runfile -x # || return -1

    pushd . >/dev/null
    cd ${runfilename%.run}
     
    # Copy NGX .dlls for DLSS support in Proton
    mkdir -p $rootfs/usr/lib/x86_64-linux-gnu/nvidia/wine
    cp *.dll $rootfs/usr/lib/x86_64-linux-gnu/nvidia/wine/

    # The Proton script uses the location of the libGLX_nvidia.so.0 DSO to locate
    # the NGX dlls. It does this by calling dlopen on the library and then obtains
    # its location in the filesystem using dlinfo. Once it has the location of the
    # DSO the relative offset of the NGX dlls is always the same. If libGLX_nvidia.so
    # can't be successfully dlopen'd the NGX dlls will not be installed into the
    # application Wine prefix.
    #
    # Because the proton script is using dlopen it is necessary to also have all
    # of the dependencies of libGLX_nvidia.so installed as well. The safest way
    # to do this is to just copy all of the library files.
    #
    # See find_nvidia_wine_dll_dir in https://github.com/ValveSoftware/Proton/blob/proton_10.0/proton
    # for all of the details. 

    # Copy 64 bit libraries
    for dso in *.so.$nvidia_driver_version; do
    cp -vf ./$dso $rootfs/lib/x86_64-linux-gnu/$dso
    pushd $rootfs/lib/x86_64-linux-gnu >/dev/null
    ln -sf $dso $(echo $dso | cut -d'.' -f1-2).0
    ln -sf $dso $(echo $dso | cut -d'.' -f1-2).1
    ln -sf $dso $(echo $dso | cut -d'.' -f1-2).2
    popd >/dev/null
    done
     
    # Copy 32 bit libraries
    cd 32
    for dso in *.so.$nvidia_driver_version; do
    cp -vf ./$dso $rootfs/lib/i386-linux-gnu/$dso
    pushd $rootfs/lib/i386-linux-gnu >/dev/null
    ln -sf $dso $(echo $dso | cut -d'.' -f1-2).0
    ln -sf $dso $(echo $dso | cut -d'.' -f1-2).1
    ln -sf $dso $(echo $dso | cut -d'.' -f1-2).2
    popd >/dev/null
    done

    popd >/dev/null
fi

if ! sudo patch --dry-run -R -p1 /usr/lib/steam/bin_steam.sh < patch_steam_for_arm64.patch &>/dev/null; then
    echo "Patching Steam launcher to automatically invoke with FEXBash on arm64..."
    sudo patch -p1 /usr/lib/steam/bin_steam.sh < patch_steam_for_arm64.patch
fi

echo "---"
echo "Installation complete!"
echo "We recommend running sudo apt update && sudo apt upgrade to ensure everything on your host is up-to-date"
echo "---"

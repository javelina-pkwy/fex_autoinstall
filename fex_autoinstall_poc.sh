#!/bin/bash

# Usage: wget https://raw.githubusercontent.com/MitchellAugustin/fex_autoinstall/refs/heads/main/fex_autoinstall_poc.sh && bash fex_autoinstall_poc.sh

# Exit immediately if a command exits with a non-zero status.
set -e

ORIG_DIR=$(pwd)

TEMP_DIR=$(mktemp -d)

cleanup() {
  cd "$ORIG_DIR"
  rm -rf "$TEMP_DIR"
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
      echo "  $((i - start + 1))) ${items[$i]}" >&2
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
ARCHIVE_REPO="javelina-pkwy/Unofficial-FEX-Package-Archive"

INSTALL_MODE=1
echo ""
echo "How would you like to install FEX?"
echo "  1) Latest release from the FEX-Emu PPA (recommended)"
if [ "$ARM_PLATFORM_VERSION" = "armv8.4" ]; then
  echo "  2) Choose a specific FEX release (or the nightly build) from the Unofficial FEX Package Archive"
  while true; do
    read -rp "Select [1-2] (default: 1): " INSTALL_MODE
    INSTALL_MODE=${INSTALL_MODE:-1}
    case "$INSTALL_MODE" in
      1|2) break;;
      *) echo "Please enter 1 or 2.";;
    esac
  done
else
  echo "  (Specific releases from the Unofficial FEX Package Archive are only available for armv8.4 hosts.)"
fi

echo "Adding FEX-Emu PPA..."
sudo add-apt-repository -y ppa:fex-emu/fex
sudo apt update

echo "Installing FEX-Emu Wine, Vulkan packages, and tools..."
sudo apt install -y fex-emu-wine patchelf mesa-vulkan-drivers jq

if [ "$INSTALL_MODE" = "2" ]; then
  echo "Fetching available releases from $ARCHIVE_REPO..."
  RELEASES_JSON=$(curl -fsSL "https://api.github.com/repos/$ARCHIVE_REPO/releases?per_page=100")
  # One "<label><TAB><deb url>" line per release: the nightly (if any) first, then tagged
  # releases newest first.
  mapfile -t ARCHIVE_RELEASES < <(
    jq -r '.[] | select(.draft == false and .tag_name == "nightly")
        | "\(.name)\t\(.assets[] | select(.name | endswith(".deb")) | .browser_download_url)"' <<<"$RELEASES_JSON"
    jq -r '.[] | select(.draft == false and (.tag_name | test("^FEX-[0-9.]+$")))
        | "\(.tag_name)\t\(.assets[] | select(.name | endswith(".deb")) | .browser_download_url)"' <<<"$RELEASES_JSON" \
      | sort -t$'\t' -k1,1rV | sed '1s/\t/ (latest release)\t/')
  if [ ${#ARCHIVE_RELEASES[@]} -eq 0 ]; then
    echo "No releases found in $ARCHIVE_REPO; installing the latest PPA release instead."
    INSTALL_MODE=1
  fi
fi

if [ "$INSTALL_MODE" = "1" ]; then
  echo "Installing FEX-Emu from the PPA..."
  sudo apt install -y "$FEX_PACKAGE"
else
  mapfile -t ARCHIVE_LABELS < <(printf '%s\n' "${ARCHIVE_RELEASES[@]}" | cut -f1)
  FEX_CHOICE=$(paged_select "Which FEX release do you want to install?" "${ARCHIVE_LABELS[@]}")
  FEX_DEB_URL=$(printf '%s\n' "${ARCHIVE_RELEASES[@]}" | awk -F'\t' -v t="$FEX_CHOICE" '$1 == t {print $2}')
  FEX_TAG=${FEX_CHOICE%% (*}

  echo "Downloading $FEX_CHOICE..."
  wget -q "$FEX_DEB_URL" "${FEX_DEB_URL%/*}/SHA256SUMS"
  sha256sum -c SHA256SUMS
  sudo apt install -y ./Unofficial-*.deb
  # Keep apt from replacing the chosen release with the PPA's latest on upgrade.
  sudo apt-mark hold "$FEX_PACKAGE"
  echo "$FEX_PACKAGE is held at $FEX_TAG; run 'sudo apt-mark unhold $FEX_PACKAGE' to allow PPA upgrades again."
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

#!/bin/sh
#
# Tenstorrent Stack Install Script (Based on Lambda Stack Style)
# The original Lambda Stack is here: https://lambda.ai/lambda-stack-deep-learning-software
#
# Installs Tenstorrent system-level dependencies for Ubuntu 22.04.
# Based on Tenstorrent Starting Guide documentation.
#
# WARNING: This script installs system-level software, including kernel modules
# and firmware. Review carefully before executing. It assumes you have
# administrator privileges (sudo).
#
# NOTE: Tenstorrent software components have specific version compatibilities.
# This script uses versions mentioned in the provided documentation snapshot.
# Always consult the official Tenstorrent SDK compatibility matrices for the
# latest and correct versions for your specific SDK usage.
#
set -eu

# --- Configuration ---
# Versions based on the provided Tenstorrent Starting Guide snapshot
TT_KMD_VERSION="1.31" # Corresponds to dkms install tenstorrent/<version>
TT_KMD_REPO="https://github.com/tenstorrent/tt-kmd.git"

TT_FLASH_REPO="https://github.com/tenstorrent/tt-flash.git"

TT_FIRMWARE_VERSION="fw_pack-80.15.0.0.fwbundle"
TT_FIRMWARE_URL="https://github.com/tenstorrent/tt-firmware/raw/main/${TT_FIRMWARE_VERSION}" # Adjust if URL structure changes

# Using release 1.1 as specified, check TT-System-Tools repo for latest if needed
TT_SYSTEM_TOOLS_VERSION="1.1"
TT_SYSTEM_TOOLS_DEB_FILENAME="tenstorrent-tools_1.1-5_all.deb" # Specific filename from docs
TT_SYSTEM_TOOLS_URL="https://github.com/tenstorrent/tt-system-tools/releases/download/upstream%2F${TT_SYSTEM_TOOLS_VERSION}/${TT_SYSTEM_TOOLS_DEB_FILENAME}"

TT_TOPOLOGY_REPO="https://github.com/tenstorrent/tt-topology"
TT_SMI_REPO="https://github.com/tenstorrent/tt-smi"

# --- Helper Functions ---
stderr() {
    >&2 echo "$@"
}

fatal() {
    stderr "ERROR: $@"
    exit 1
}

# --- Main Installation Logic ---
main() {
    # Check that user is running a supported distribution
    if ! . /etc/lsb-release; then
        fatal "tenstorrent-stack-install: No /etc/lsb-release file. Unable to detect distribution."
    fi
    if [ "$DISTRIB_ID" != "Ubuntu" ]; then
        stderr "tenstorrent-stack-install: '$DISTRIB_ID' is not a supported software distribution."
        fatal "Tenstorrent Stack installation currently targets Ubuntu."
    fi
    case "$DISTRIB_RELEASE" in
        22.04)
            stderr "Ubuntu $DISTRIB_RELEASE (Jammy Jellyfish) detected. Proceeding..."
            ;;
        *)
            stderr "tenstorrent-stack-install: 'Ubuntu $DISTRIB_RELEASE' is not the recommended distribution."
            stderr "The recommended OS is Ubuntu 22.04 LTS (Jammy Jellyfish)."
            stderr "Installation on other versions is experimental and may not work."
            # Ask user to confirm if they want to proceed on non-recommended Ubuntu
            printf "Do you want to attempt installation anyway? (y/N): "
            read -r confirmation
            case "$confirmation" in
                [yY][eE][sS]|[yY])
                    stderr "Proceeding with installation on untested Ubuntu version."
                    ;;
                *)
                    fatal "Installation aborted by user."
                    ;;
            esac
            ;;
    esac

    # Check for root privileges needed for installs
    if [ "$(id -u)" -ne 0 ]; then
        stderr "This script requires root privileges for installation steps."
        stderr "Attempting to run commands with sudo..."
        # Test sudo availability early
        if ! sudo -v; then
            fatal "sudo command failed or password incorrect. Please ensure you have sudo privileges."
        fi
    fi

    # --- Step 0: Update package list and Install Prerequisites ---
    stderr "Step 0: Updating package list and installing prerequisites..."
    sudo apt-get update || fatal "Failed to update package lists."
    sudo apt-get install -y wget git python3-pip dkms cargo || fatal "Failed to install prerequisite packages."
    stderr "Prerequisites installed successfully."
    # Check if pip is functional
    if ! command -v pip3 > /dev/null; then
        fatal "pip3 command not found after installation. Please check Python/pip setup."
    fi

    # --- Step 1: Install the Kernel-Mode Driver (TT-KMD) ---
    stderr "\nStep 1: Installing Tenstorrent Kernel-Mode Driver (TT-KMD)..."
    KMD_TEMP_DIR=$(mktemp -d -t tt-kmd-install-XXXXXX)
    stderr "Cloning TT-KMD repository into ${KMD_TEMP_DIR}..."
    git clone --depth 1 "${TT_KMD_REPO}" "${KMD_TEMP_DIR}" || fatal "Failed to clone TT-KMD repository."
    cd "${KMD_TEMP_DIR}"

    stderr "Adding TT-KMD module to DKMS..."
    sudo dkms add . || fatal "Failed to add TT-KMD to DKMS."

    stderr "Building and installing TT-KMD module via DKMS (Version: ${TT_KMD_VERSION})..."
    # The dkms install command format is usually <module_name>/<module_version>
    # Assuming the module name defined in dkms.conf is 'tenstorrent'
    sudo dkms install "tenstorrent/${TT_KMD_VERSION}" || fatal "Failed to install TT-KMD module via DKMS. Check version and build logs."

    stderr "Loading TT-KMD module..."
    sudo modprobe tenstorrent || fatal "Failed to load tenstorrent kernel module using modprobe. Check dmesg for errors."

    stderr "TT-KMD installed and loaded successfully."
    cd - > /dev/null # Go back to original directory
    rm -rf "${KMD_TEMP_DIR}" # Clean up temporary clone directory
    stderr "Cleaned up temporary TT-KMD directory."

    # --- Step 2: Install TT-Flash Utility ---
    stderr "\nStep 2: Installing TT-Flash utility..."
    stderr "NOTE: Installing Python package system-wide via pip. Consider using a virtual environment (venv) or pipx for better isolation, especially if you encounter 'externally-managed-environment' errors."
    sudo pip3 install --upgrade pip # Ensure pip is up-to-date
    sudo pip3 install "git+${TT_FLASH_REPO}" || fatal "Failed to install TT-Flash utility via pip."
    # Verify tt-flash command exists
    if ! command -v tt-flash > /dev/null; then
         # Pip might install to ~/.local/bin, check if it's in PATH
         if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
              stderr "WARNING: tt-flash installed but $HOME/.local/bin is not in your PATH."
              stderr "You may need to add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to your ~/.bashrc or ~/.profile"
              # Try running it directly for the next step anyway
              export PATH="$HOME/.local/bin:$PATH"
              if ! command -v tt-flash > /dev/null; then
                   fatal "tt-flash command not found even after adding ~/.local/bin to PATH."
              fi
         else
              fatal "tt-flash command not found after installation. Check pip install logs."
         fi
    fi
    stderr "TT-Flash installed successfully."

    # --- Step 3: Download and Update Device Firmware ---
    stderr "\nStep 3: Updating Tenstorrent Device Firmware..."
    FIRMWARE_TEMP_FILE=$(mktemp -t tt-firmware-XXXXXX.fwbundle)
    stderr "Downloading firmware bundle (${TT_FIRMWARE_VERSION})..."
    wget --quiet -O "${FIRMWARE_TEMP_FILE}" "${TT_FIRMWARE_URL}" || fatal "Failed to download firmware file from ${TT_FIRMWARE_URL}"
    stderr "Firmware downloaded to ${FIRMWARE_TEMP_FILE}."

    stderr "Attempting to flash firmware using TT-Flash..."
    # Run tt-flash with sudo as it likely needs hardware access
    if sudo tt-flash --fw-tar "${FIRMWARE_TEMP_FILE}"; then
        stderr "Firmware flash command executed. Check output for success/failure details."
        stderr "IMPORTANT: A system reboot is REQUIRED to apply the new firmware."
    else
        stderr "Firmware flash command failed."
        stderr "This might be expected if the existing firmware is newer or the same."
        stderr "If the error indicates the new firmware is older than required, you might need to use the '--force' flag."
        stderr "Example: sudo tt-flash --fw-tar ${FIRMWARE_TEMP_FILE} --force"
        stderr "Consult Tenstorrent documentation if issues persist."
        # Don't consider this fatal automatically, but warn heavily.
    fi
    rm -f "${FIRMWARE_TEMP_FILE}" # Clean up temporary firmware file

    # --- Step 4: Set Up HugePages ---
    stderr "\nStep 4: Setting up HugePages..."
    HUGEPAGES_TEMP_DEB=$(mktemp -t tenstorrent-tools-XXXXXX.deb)
    stderr "Downloading tenstorrent-tools package..."
    wget --quiet -O "${HUGEPAGES_TEMP_DEB}" "${TT_SYSTEM_TOOLS_URL}" || fatal "Failed to download tenstorrent-tools .deb package from ${TT_SYSTEM_TOOLS_URL}"
    stderr "Package downloaded to ${HUGEPAGES_TEMP_DEB}."

    stderr "Installing tenstorrent-tools package..."
    sudo dpkg -i "${HUGEPAGES_TEMP_DEB}" || fatal "Failed to install tenstorrent-tools .deb package."
    # dpkg doesn't handle dependencies, apt install might be needed if it fails
    # sudo apt-get install -f -y # Uncomment this line if dpkg fails due to dependencies

    stderr "Enabling and starting HugePages services..."
    sudo systemctl enable --now tenstorrent-hugepages.service || fatal "Failed to enable/start tenstorrent-hugepages.service."
    # The mount unit name needs careful escaping for systemctl
    sudo systemctl enable --now 'dev-hugepages\x2d1G.mount' || fatal "Failed to enable/start dev-hugepages\\x2d1G.mount."

    stderr "HugePages configuration applied."
    stderr "NOTE: A system reboot is recommended to ensure HugePages are fully configured and available at boot."
    rm -f "${HUGEPAGES_TEMP_DEB}" # Clean up temporary deb file

    # --- Step 5: (Optional) Install TT-Topology ---
    stderr "\nStep 5: Installing TT-Topology (Optional, for multi-card systems)..."
    stderr "NOTE: This is typically only needed if you modify the topology of a multi-card system like TT-LoudBox/QuietBox."
    sudo pip3 install "git+${TT_TOPOLOGY_REPO}" || fatal "Failed to install TT-Topology utility via pip."
    stderr "TT-Topology installed. Run 'tt-topology -l mesh' manually if needed to configure topology."

    # --- Step 6: Install TT-SMI ---
    stderr "\nStep 6: Installing Tenstorrent System Management Interface (TT-SMI)..."
    sudo pip3 install "git+${TT_SMI_REPO}" || fatal "Failed to install TT-SMI utility via pip."
     # Verify tt-smi command exists (similar check as tt-flash)
    if ! command -v tt-smi > /dev/null; then
         if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
              stderr "WARNING: tt-smi installed but $HOME/.local/bin is not in your PATH."
              export PATH="$HOME/.local/bin:$PATH" # Add for verification step
              if ! command -v tt-smi > /dev/null; then
                   fatal "tt-smi command not found even after adding ~/.local/bin to PATH."
              fi
         else
              fatal "tt-smi command not found after installation. Check pip install logs."
         fi
    fi
    stderr "TT-SMI installed successfully."

    # --- Step 7: Verification Prompt ---
    stderr "\nStep 7: Verifying System Configuration..."
    stderr "Attempting to run tt-smi to check device detection and status."
    stderr "Please check the output carefully for errors or warnings."
    if sudo tt-smi; then
        stderr "tt-smi executed successfully. Review the output above."
    else
        stderr "WARNING: tt-smi command failed or returned an error."
        stderr "This may indicate issues with KMD, firmware, permissions, or hardware detection."
        stderr "A reboot is often required after installation. Try rebooting and running 'sudo tt-smi' again."
    fi

    # --- Final Instructions ---
    stderr "\n--- Tenstorrent Stack System Installation Complete ---"
    stderr "\nIMPORTANT:"
    stderr "1. A system reboot is STRONGLY RECOMMENDED to:"
    stderr "   - Apply updated device firmware (if flashed)."
    stderr "   - Ensure the kernel module (TT-KMD) is loaded correctly at boot."
    stderr "   - Ensure HugePages services and mounts are active."
    stderr "   Please run: sudo reboot"
    stderr "\n2. After rebooting, verify the installation again by running: sudo tt-smi"
    stderr "\n3. Remember to check the BIOS setting 'PCIe AER Reporting Mechanism' is set to 'OS First' if using TT-QuietBox or experiencing related issues."
    stderr "\n4. You can now proceed to install Tenstorrent SDKs like TT-Metalium or TT-Buda."
    stderr "   Consult the documentation for each SDK for specific installation instructions and compatibility requirements."
    stderr "--- End of Installation ---"
}

# --- Script Execution ---
main

exit 0

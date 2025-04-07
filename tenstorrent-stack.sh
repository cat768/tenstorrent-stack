#!/bin/bash
#
# Tenstorrent Full Stack Install Script (System + TT-Metal/NN + TT-Forge)
#
# Installs Tenstorrent system-level dependencies, TT-Metal/TT-NN SDK (from source),
# and clones the TT-Forge SDK repository for Ubuntu 22.04.
# Based on Tenstorrent Starting Guide and GitHub README documentation.
#
# WARNING: This script installs system-level software, including kernel modules,
# firmware, and numerous development packages. It clones large repositories.
# Review carefully before executing. It requires administrator privileges (sudo)
# and significant disk space (~20GB+ recommended after build).
#
# NOTE: Tenstorrent software components have specific version compatibilities.
# This script uses versions mentioned in the initial request's documentation snapshot.
# The TT-Metal README may show different compatible versions.
# **ALWAYS consult the official Tenstorrent SDK compatibility matrices for the
# correct versions for your specific hardware and SDK usage.**
#
set -euo pipefail # More robust error handling

# --- Configuration ---
# System-level versions based on the initial Tenstorrent Starting Guide snapshot
TT_KMD_VERSION="1.31" # Corresponds to dkms install tenstorrent/<version>
TT_KMD_REPO="https://github.com/tenstorrent/tt-kmd.git"

TT_FLASH_REPO="https://github.com/tenstorrent/tt-flash.git"

TT_FIRMWARE_VERSION="fw_pack-80.15.0.0.fwbundle"
TT_FIRMWARE_URL="https://github.com/tenstorrent/tt-firmware/raw/main/${TT_FIRMWARE_VERSION}" # Adjust if URL structure changes

TT_SYSTEM_TOOLS_VERSION="1.1"
TT_SYSTEM_TOOLS_DEB_FILENAME="tenstorrent-tools_1.1-5_all.deb"
TT_SYSTEM_TOOLS_URL="https://github.com/tenstorrent/tt-system-tools/releases/download/upstream%2F${TT_SYSTEM_TOOLS_VERSION}/${TT_SYSTEM_TOOLS_DEB_FILENAME}"

TT_TOPOLOGY_REPO="https://github.com/tenstorrent/tt-topology"
TT_SMI_REPO="https://github.com/tenstorrent/tt-smi"

# SDK Repositories
TT_METAL_REPO="https://github.com/tenstorrent/tt-metal.git"
TT_FORGE_REPO="https://github.com/tenstorrent/tt-forge-fe.git" # Note: Changed repo name based on URL in Forge text

# Installation Directory (configurable if needed)
INSTALL_DIR="${HOME}/tenstorrent" # Install SDKs into ~/tenstorrent/

# --- Helper Functions ---
stderr() {
    echo "$@" >&2
}

fatal() {
    stderr "ERROR: $@"
    exit 1
}

step_header() {
    stderr "\n--------------------------------------------------"
    stderr "$1"
    stderr "--------------------------------------------------"
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command '$1' not found. Please install it."
}

add_to_path_if_missing() {
    local dir_to_add="$1"
    if [[ ":$PATH:" != *":${dir_to_add}:"* ]]; then
        stderr "Adding ${dir_to_add} to PATH for this session."
        export PATH="${dir_to_add}:${PATH}"
        # Also remind user to add it permanently
        stderr "NOTE: You may need to add '${dir_to_add}' to your PATH permanently in ~/.bashrc or ~/.profile."
    fi
}


# --- Main Installation Logic ---
main() {
    # --- Initial Checks ---
    step_header "Phase 0: Initial System Checks"

    # Check OS (Allowing user override for experimental installs)
    if ! source /etc/lsb-release; then
        fatal "No /etc/lsb-release file. Unable to detect distribution."
    fi
    if [[ "$DISTRIB_ID" != "Ubuntu" ]]; then
        fatal "'$DISTRIB_ID' is not a supported distribution. Tenstorrent Stack installation targets Ubuntu 22.04."
    fi
    if [[ "$DISTRIB_RELEASE" != "22.04" ]]; then
        stderr "WARNING: 'Ubuntu $DISTRIB_RELEASE' is not the recommended distribution (Ubuntu 22.04 LTS)."
        read -p "Attempt installation anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            fatal "Installation aborted by user."
        fi
        stderr "Proceeding with installation on untested Ubuntu version."
    else
        stderr "Ubuntu $DISTRIB_RELEASE (Jammy Jellyfish) detected."
    fi

    # Check for root privileges / sudo capability
    if ! sudo -v; then
       fatal "Failed to acquire sudo privileges. Please ensure you can run sudo commands."
    fi
    stderr "Sudo privileges acquired."

    # Check essential commands
    check_command wget
    check_command git
    check_command python3
    check_command pip3
    check_command cargo

    # --- Phase 1: System-Level Dependencies ---
    step_header "Phase 1: Installing System-Level Prerequisites & Drivers"

    stderr "Updating package list..."
    sudo apt-get update || fatal "Failed to update package lists."

    stderr "Installing base prerequisites (dkms)..."
    # dkms and cargo should already be checked, but install explicitly
    sudo apt-get install -y dkms || fatal "Failed to install dkms."
    stderr "Base prerequisites installed."

    stderr "Downloading and running TT-Metal dependency installation script..."
    wget https://raw.githubusercontent.com/tenstorrent/tt-metal/main/install_dependencies.sh -O /tmp/install_dependencies.sh || fatal "Failed to download install_dependencies.sh"
    chmod +x /tmp/install_dependencies.sh
    # This script installs many packages (build-essential, cmake, llvm, clang, python deps, etc.)
    sudo /tmp/install_dependencies.sh || fatal "TT-Metal dependency script failed."
    rm /tmp/install_dependencies.sh
    stderr "TT-Metal dependencies installed."

    # Install TT-KMD (Kernel Module)
    stderr "Installing Tenstorrent Kernel-Mode Driver (TT-KMD)..."
    KMD_TEMP_DIR=$(mktemp -d -t tt-kmd-install-XXXXXX)
    stderr "Cloning TT-KMD repository into ${KMD_TEMP_DIR}..."
    git clone --depth 1 --branch "v${TT_KMD_VERSION}" "${TT_KMD_REPO}" "${KMD_TEMP_DIR}" || fatal "Failed to clone TT-KMD repository (v${TT_KMD_VERSION}). Check version tag exists."
    cd "${KMD_TEMP_DIR}"
    stderr "Adding TT-KMD module to DKMS..."
    sudo dkms add . || fatal "Failed to add TT-KMD to DKMS."
    stderr "Building and installing TT-KMD module via DKMS (Version: ${TT_KMD_VERSION})..."
    sudo dkms install "tenstorrent/${TT_KMD_VERSION}" || fatal "Failed to install TT-KMD module via DKMS. Check version and build logs in /var/lib/dkms/tenstorrent/${TT_KMD_VERSION}/build/make.log"
    stderr "Loading TT-KMD module..."
    sudo modprobe tenstorrent || fatal "Failed to load tenstorrent kernel module using modprobe. Check dmesg for errors."
    stderr "TT-KMD installed and loaded successfully."
    cd - > /dev/null # Go back to original directory
    rm -rf "${KMD_TEMP_DIR}"
    stderr "Cleaned up temporary TT-KMD directory."

    # Install TT-Flash
    stderr "Installing TT-Flash utility..."
    stderr "NOTE: Installing Python packages system-wide via sudo pip3. Consider using user installs (--user) or virtual environments if preferred."
    sudo pip3 install --upgrade pip # Ensure pip is up-to-date
    sudo pip3 install "git+${TT_FLASH_REPO}" || fatal "Failed to install TT-Flash utility via pip."
    add_to_path_if_missing "$HOME/.local/bin" # Add user bin dir if it exists
    check_command tt-flash
    stderr "TT-Flash installed successfully."

    # Download and Flash Firmware
    # **Requires Reboot**
    stderr "Updating Tenstorrent Device Firmware (Version: ${TT_FIRMWARE_VERSION})..."
    FIRMWARE_TEMP_FILE=$(mktemp -t tt-firmware-XXXXXX.fwbundle)
    stderr "Downloading firmware bundle..."
    wget --quiet -O "${FIRMWARE_TEMP_FILE}" "${TT_FIRMWARE_URL}" || fatal "Failed to download firmware file from ${TT_FIRMWARE_URL}"
    stderr "Firmware downloaded to ${FIRMWARE_TEMP_FILE}."
    stderr "Attempting to flash firmware using TT-Flash..."
    stderr "NOTE: If this fails stating the firmware is too old, you might need '--force'."
    if sudo tt-flash --fw-tar "${FIRMWARE_TEMP_FILE}"; then
        stderr "Firmware flash command executed. Check output. A REBOOT IS REQUIRED."
    else
        stderr "Firmware flash command failed. This might be okay if firmware is already up-to-date."
        stderr "If you see errors about the new firmware being older, consider running manually with --force:"
        stderr "sudo tt-flash --fw-tar ${FIRMWARE_TEMP_FILE} --force"
        stderr "A REBOOT IS LIKELY STILL REQUIRED."
    fi
    rm -f "${FIRMWARE_TEMP_FILE}"
    stderr "!! IMPORTANT: REBOOT your system now to apply firmware and ensure KMD loads correctly !!"
    read -p "Press Enter to continue AFTER rebooting, or Ctrl+C to exit and reboot manually: " wait_for_reboot

    # Setup HugePages
    # **Requires Reboot** (Best practice to do after KMD/FW reboot)
    step_header "Phase 2: Configuring System Services (HugePages)"
    stderr "Setting up HugePages..."
    HUGEPAGES_TEMP_DEB=$(mktemp -t tenstorrent-tools-XXXXXX.deb)
    stderr "Downloading tenstorrent-tools package..."
    wget --quiet -O "${HUGEPAGES_TEMP_DEB}" "${TT_SYSTEM_TOOLS_URL}" || fatal "Failed to download tenstorrent-tools .deb from ${TT_SYSTEM_TOOLS_URL}"
    stderr "Installing tenstorrent-tools package..."
    sudo dpkg -i "${HUGEPAGES_TEMP_DEB}" || { sudo apt-get install -f -y && sudo dpkg -i "${HUGEPAGES_TEMP_DEB}"; } || fatal "Failed to install tenstorrent-tools .deb package."
    stderr "Enabling and starting HugePages services..."
    sudo systemctl enable --now tenstorrent-hugepages.service || fatal "Failed to enable/start tenstorrent-hugepages.service."
    sudo systemctl enable --now 'dev-hugepages\x2d1G.mount' || fatal "Failed to enable/start dev-hugepages\\x2d1G.mount."
    rm -f "${HUGEPAGES_TEMP_DEB}"
    stderr "HugePages configuration applied."
    stderr "!! IMPORTANT: Another REBOOT is recommended to ensure HugePages are correctly set up at boot time !!"
    read -p "Press Enter to continue AFTER the second reboot, or Ctrl+C to exit and reboot manually: " wait_for_reboot2


    # Install TT-SMI & Optional TT-Topology
    step_header "Phase 3: Installing Management & Optional Tools"
    stderr "Installing TT-SMI (System Management Interface)..."
    sudo pip3 install "git+${TT_SMI_REPO}" || fatal "Failed to install TT-SMI utility via pip."
    add_to_path_if_missing "$HOME/.local/bin" # Re-check PATH after potential reboot
    check_command tt-smi
    stderr "TT-SMI installed successfully."
    stderr "Verifying system with TT-SMI..."
    if sudo tt-smi; then
        stderr "tt-smi executed successfully. Review the output above."
    else
        stderr "WARNING: tt-smi command failed or returned an error. Check KMD, Firmware, HugePages, Permissions, and Hardware."
        fatal "TT-SMI verification failed. Cannot proceed reliably."
    fi

    read -p "Install optional TT-Topology utility (Needed for multi-card TT-LoudBox/QuietBox topology changes)? (y/N): " install_topology
    if [[ "$install_topology" =~ ^[Yy]$ ]]; then
        stderr "Installing TT-Topology..."
        sudo pip3 install "git+${TT_TOPOLOGY_REPO}" || fatal "Failed to install TT-Topology utility via pip."
        check_command tt-topology
        stderr "TT-Topology installed. Run 'tt-topology -l mesh' manually if needed."
    fi

    # --- Phase 4: Install TT-Metal / TT-NN SDK ---
    step_header "Phase 4: Installing TT-Metal / TT-NN SDK (from Source)"
    stderr "This will clone the repository into ${INSTALL_DIR}/tt-metal"
    stderr "The build process can take a significant amount of time and disk space."
    read -p "Proceed with TT-Metal/TT-NN installation? (Y/n): " install_metal
    if [[ "$install_metal" =~ ^[Nn]$ ]]; then
        stderr "Skipping TT-Metal/TT-NN installation."
    else
        mkdir -p "${INSTALL_DIR}" || fatal "Failed to create installation directory: ${INSTALL_DIR}"
        cd "${INSTALL_DIR}" || fatal "Failed to change directory to ${INSTALL_DIR}"

        stderr "Cloning TT-Metal repository with submodules (this may take a while)..."
        git clone --recurse-submodules "${TT_METAL_REPO}" || fatal "Failed to clone TT-Metal repository."
        cd tt-metal || fatal "Failed to enter tt-metal directory."

        stderr "Running TT-Metal build script (./build_metal.sh)... This is a long process!"
        ./build_metal.sh || fatal "TT-Metal build script failed."
        stderr "TT-Metal build completed."

        stderr "Creating Python virtual environment using ./create_venv.sh..."
        ./create_venv.sh || fatal "Failed to create Python virtual environment."
        stderr "Virtual environment created in 'python_env'."

        stderr "Activating virtual environment temporarily to install further dependencies..."
        # shellcheck source=/dev/null
        source python_env/bin/activate || fatal "Failed to activate python_env."

        stderr "Installing development/model requirements inside the virtual environment..."
        pip install -r tt_metal/python_env/requirements-dev.txt || fatal "Failed to install requirements-dev.txt"
        stderr "Development requirements installed."

        read -p "Install optional profiling dependencies (pandoc, libtbb-dev, etc.)? (y/N): " install_profiling_deps
        if [[ "$install_profiling_deps" =~ ^[Yy]$ ]]; then
            stderr "Installing profiling dependencies..."
            sudo apt-get install -y pandoc libtbb-dev libcapstone-dev pkg-config || fatal "Failed to install profiling dependencies."
            # Doxygen install needs specific version check - instruct user
            stderr "Profiling dependencies installed. NOTE: TT-Metal requires Doxygen v1.9.x (but < 1.10). Please install it manually if needed (e.g., download from doxygen.nl)."
        fi

        # Deactivate venv for now, user needs to activate it manually later
        deactivate
        stderr "TT-Metal/TT-NN installation steps completed."
        cd "${INSTALL_DIR}" # Go back to base install dir
    fi

    # --- Phase 5: Install TT-Forge SDK ---
    step_header "Phase 5: Setting up TT-Forge SDK (Cloning Repository)"
    stderr "This will clone the repository into ${INSTALL_DIR}/tt-forge-fe"
    stderr "Building TT-Forge from source requires additional steps described in its README."
    read -p "Clone the TT-Forge repository? (Y/n): " install_forge
    if [[ "$install_forge" =~ ^[Nn]$ ]]; then
        stderr "Skipping TT-Forge setup."
    else
        mkdir -p "${INSTALL_DIR}" || fatal "Failed to create installation directory: ${INSTALL_DIR}"
        cd "${INSTALL_DIR}" || fatal "Failed to change directory to ${INSTALL_DIR}"

        stderr "Cloning TT-Forge repository..."
        git clone "${TT_FORGE_REPO}" || fatal "Failed to clone TT-Forge repository."
        stderr "TT-Forge repository cloned into '${INSTALL_DIR}/tt-forge-fe'."
        stderr "To build TT-Forge:"
        stderr "1. cd ${INSTALL_DIR}/tt-forge-fe"
        stderr "2. Follow the build instructions in the README.md or relevant documentation within that repository."
        stderr "   (This typically involves installing prerequisites and running cmake/make)."
        stderr "Alternatively, check the TT-Forge releases page for pre-built wheel files:"
        stderr "   https://github.com/tenstorrent/tt-forge/releases"

        cd "${INSTALL_DIR}" # Go back to base install dir
    fi


    # --- Final Instructions ---
    step_header "Installation Summary & Next Steps"
    stderr "Tenstorrent system components and SDK setup script finished."

    stderr "\nRecap:"
    stderr "- System drivers (TT-KMD), firmware, HugePages, TT-SMI installed/configured."
    if [[ ! "$install_metal" =~ ^[Nn]$ ]]; then
        stderr "- TT-Metal/TT-NN SDK cloned to '${INSTALL_DIR}/tt-metal', built, and venv created."
    fi
    if [[ ! "$install_forge" =~ ^[Nn]$ ]]; then
        stderr "- TT-Forge SDK cloned to '${INSTALL_DIR}/tt-forge-fe'."
    fi

    stderr "\n--- IMPORTANT NEXT STEPS ---"

    if [[ ! "$install_metal" =~ ^[Nn]$ ]]; then
      stderr "\n1. To use TT-Metal/TT-NN:"
      stderr "   a. Activate the virtual environment:"
      stderr "      cd ${INSTALL_DIR}/tt-metal"
      stderr "      source python_env/bin/activate"
      stderr "   b. Set environment variables (REQUIRED):"
      stderr "      export TT_METAL_HOME=\$(pwd)"
      stderr "      export PYTHONPATH=\$(pwd):\$PYTHONPATH"
      stderr "      export ARCH_NAME=<your_arch>"
      stderr "      (Replace <your_arch> with 'grayskull', 'wormhole_b0', or 'blackhole' based on your hardware)"
      stderr "   c. Verify TT-NN installation (within the activated venv):"
      stderr "      python3 -m ttnn.examples.usage.run_op_on_device"
      stderr "   d. (Optional) Set CPU governor for performance:"
      stderr "      sudo cpupower frequency-set -g performance"
    fi

    if [[ ! "$install_forge" =~ ^[Nn]$ ]]; then
      stderr "\n2. To use TT-Forge:"
      stderr "   a. Build from source (if you didn't install wheels):"
      stderr "      cd ${INSTALL_DIR}/tt-forge-fe"
      stderr "      Follow instructions in the repository's README.md"
      stderr "   b. Or, install pre-built wheels (download from GitHub releases first):"
      stderr "      pip install <tvm_wheel_file>.whl <forge_wheel_file>.whl"
      stderr "   c. Verify installation (after building/installing wheels):"
      stderr "      cd ${INSTALL_DIR}/tt-forge-fe"
      stderr "      pytest forge/test/mlir/operators/eltwise_binary/test_eltwise_binary.py::test_add"
    fi

    stderr "\n3. Remember to check the official Tenstorrent documentation and compatibility"
    stderr "   matrices for the specific SDK versions you intend to use."

    stderr "\n--- End of Installation Script ---"
}

# --- Script Execution ---
main

exit 0
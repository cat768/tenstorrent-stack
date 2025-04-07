# Tenstorrent Stack Installer 🚀

**Automated Tenstorrent Full Stack Installation for Ubuntu 22.04**

[![OS: Ubuntu 22.04](https://img.shields.io/badge/OS-Ubuntu%2022.04-blue)](https://ubuntu.com/download/desktop)

Inspired by the convenience of [Lambda Stack](https://lambdalabs.com/lambda-stack-deep-learning-software), this repository provides a shell script (`tenstorrent-stack.sh`) designed to automate the complex setup process for the Tenstorrent software stack on **Ubuntu 22.04 LTS**.

The goal is to minimize the manual configuration and dependency wrestling required to get a Tenstorrent development environment up and running, covering system-level components, the TT-Metal/TT-NN SDK, and the TT-Forge SDK.

---

## What it Installs

This script automates the installation and configuration of the following components:

1.  **System-Level Prerequisites:**
    *   Core development tools (`build-essential`, `cmake`, `llvm`, `clang`, etc. via the official TT-Metal `install_dependencies.sh` script).
    *   `dkms` for kernel module management.
    *   Rust (`cargo`).
2.  **Tenstorrent System Drivers & Tools:**
    *   **Tenstorrent Kernel Module (TT-KMD):** Installs the specified version via DKMS and loads the module.
    *   **Tenstorrent Firmware:** Downloads the specified firmware bundle and uses `tt-flash` to attempt an update (requires reboot).
    *   **Tenstorrent Flash Utility (TT-Flash):** Installs the utility via `pip`.
    *   **Tenstorrent Tools (`tenstorrent-tools`):** Installs the `.deb` package to configure HugePages services (requires reboot).
    *   **Tenstorrent System Management Interface (TT-SMI):** Installs the utility via `pip` for device monitoring.
3.  **Tenstorrent SDKs (Optional):**
    *   **(Optional) TT-Metal / TT-NN SDK:**
        *   Clones the `tt-metal` repository (with submodules) from GitHub.
        *   Builds the SDK from source (`./build_metal.sh`).
        *   Creates a dedicated Python virtual environment (`python_env`) and installs Python dependencies.
    *   **(Optional) TT-Forge SDK:**
        *   Clones the `tt-forge-fe` repository from GitHub.
        *   *Note: Building TT-Forge requires separate manual steps after cloning (see Post-Installation).*

---

## Prerequisites

Before running the script, ensure you have:

*   **Operating System:** Ubuntu 22.04 LTS (Jammy Jellyfish) is **strongly recommended**. The script includes a check but allows overriding for other Ubuntu versions at your own risk.
*   **Hardware:** A system with compatible Tenstorrent hardware (e.g., Grayskull, Wormhole, Blackhole).
*   **Permissions:** `sudo` / administrator privileges are required for system-level package installation, DKMS, firmware flashing, and service management.
*   **Internet Connection:** Required to download packages, clone repositories, and fetch dependencies.
*   **Base Tools:** `git`, `wget`, `python3`, `pip3`, `cargo`. The script checks for these.
*   **Disk Space:** Significant free disk space is needed. Recommend **~30GB+** to accommodate repositories, build artifacts, and installed packages.

---

## ⚠️ Important Warnings & Considerations

*   **System Modifications:** This script performs **significant system-level changes**, including installing kernel modules, potentially flashing device firmware, installing numerous packages via `apt` and `pip` (some globally with `sudo pip3`), and modifying system services (HugePages). **Review the script carefully before execution.** Use at your own risk.
*   **Multiple Reboots Required:** The script will prompt you to **reboot your system twice**:
    1.  After the firmware update attempt and TT-KMD installation.
    2.  After configuring HugePages.
    These reboots are crucial for the changes to take effect properly.
*   **Version Compatibility:** The script uses specific versions of TT-KMD, Firmware, and other tools defined in the configuration section. These versions were based on documentation available at a specific time. **ALWAYS consult the official Tenstorrent SDK documentation and compatibility matrices for the versions appropriate for your specific hardware and SDK usage scenario.** Using incompatible versions can lead to errors or unexpected behavior.
*   **`sudo pip3 install`:** The script installs `tt-flash`, `tt-smi`, and (optionally) `tt-topology` system-wide using `sudo pip3`. If you prefer isolated environments, consider modifying the script to use `pip3 install --user` or manage these tools within virtual environments manually.
*   **Long Build Time:** Building the TT-Metal SDK from source (`./build_metal.sh`) can take a **very long time** (potentially hours depending on your system).
*   **Not Idempotent:** Running the script multiple times without cleaning up previous installations may lead to unexpected results or errors. It's designed for a fresh setup.

---

## Installation

1.  **Clone the Repository:**
    ```bash
    git clone https://github.com/cat768/tenstorrent-stack.git
    cd tenstorrent-stack
    ```

2.  **Make the Script Executable:**
    ```bash
    chmod +x tenstorrent-stack.sh
    ```

3.  **Review the Script (Recommended):**
    Open `tenstorrent-stack.sh` in a text editor and review the commands, versions, and installation paths.

4.  **Run the Script:**
    ```bash
    ./tenstorrent-stack.sh
    ```
    The script will prompt for `sudo` password when needed and pause for the required reboots. Follow the on-screen instructions.

---

## Post-Installation Steps

After the script completes successfully and you have performed the final reboot:

**1. Verify System Components:**
*   Check KMD status: `lsmod | grep tenstorrent` (should show the module loaded)
*   Check HugePages: `cat /proc/meminfo | grep Huge`
*   Verify device detection: `sudo tt-smi` (should list your Tenstorrent devices)

**2. Using TT-Metal / TT-NN (if installed):**
*   Navigate to the TT-Metal directory:
    ```bash
    cd ~/tenstorrent/tt-metal # Or your chosen INSTALL_DIR
    ```
*   Activate the Python virtual environment:
    ```bash
    source python_env/bin/activate
    ```
*   **Set Required Environment Variables:** (You might want to add these to your `~/.bashrc` or `~/.profile` for persistence within the activated venv context)
    ```bash
    export TT_METAL_HOME=$(pwd)
    export PYTHONPATH=$(pwd):$PYTHONPATH
    # Set ARCH_NAME based on your hardware: 'grayskull', 'wormhole_b0', or 'blackhole'
    export ARCH_NAME=<your_arch>
    ```
    Replace `<your_arch>` accordingly.
*   Verify TT-NN installation (within activated venv):
    ```bash
    python3 -m ttnn.examples.usage.run_op_on_device
    ```
*   (Optional) Set CPU governor for potentially better performance:
    ```bash
    sudo cpupower frequency-set -g performance
    ```

**3. Using TT-Forge (if cloned):**
*   The script only *clones* the TT-Forge repository. You need to build it manually.
*   Navigate to the TT-Forge directory:
    ```bash
    cd ~/tenstorrent/tt-forge-fe # Or your chosen INSTALL_DIR
    ```
*   **Follow the build instructions** provided in the `README.md` or documentation within the `tt-forge-fe` repository. This typically involves installing specific prerequisites (like TVM) and using `cmake` and `make`.
*   Alternatively, check the [TT-Forge Releases page](https://github.com/tenstorrent/tt-forge/releases) for pre-built Python wheel files (`.whl`). If available for your platform, you can install them using `pip`:
    ```bash
    # Assuming you downloaded the wheels after activating a suitable Python environment
    pip install <tvm_wheel_file>.whl <forge_wheel_file>.whl
    ```
*   Verify installation (after building or installing wheels):
    Refer to the TT-Forge repository's testing instructions, e.g.:
    ```bash
    pytest forge/test/mlir/operators/eltwise_binary/test_eltwise_binary.py::test_add
    ```

---

## Configuration

The script uses shell variables at the top to define versions and repository URLs (e.g., `TT_KMD_VERSION`, `TT_FIRMWARE_VERSION`, `TT_METAL_REPO`). Advanced users can modify these variables *before* running the script to target different versions, but **ensure compatibility** by checking official Tenstorrent documentation first.

---

## Disclaimer

This script is provided "as is" without warranty of any kind. The author(s) are not responsible for any damage or data loss caused by its use. **Use this script at your own risk.** Always back up important data before performing significant system modifications.

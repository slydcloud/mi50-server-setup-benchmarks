# Full Setup and Benchmark Script for AMD MI50 GPU Server

This repository contains a single integrated Bash script, `full_setup_and_benchmark.sh`, that fully configures a server instance (specifically one running an AMD MI50 GPU) and then executes a comprehensive suite of benchmarks. The script automates:

- **Server Configuration:**  
  - System update and installation of essential packages (build-essential, stress-ng, sysbench, mbw, etc.)
  - Installation of the ROCm 5.7 with HIP stack, including kernel headers and ROCm libraries.
  - Setup of a Python virtual environment with ROCm-enabled PyTorch.
  - Installation and configuration of Docker and creation of a minimal Docker image for testing.
  
- **Benchmarking Suite:**  
  - Running standard benchmarks: stress-ng (CPU and Memory), sysbench (CPU and Memory), MBW (memory bandwidth), the ROCm Bandwidth Test (run from its build directory), and a PyTorch GEMM benchmark.
  - **Custom HIP Benchmarks:**  
    The script creates, compiles, and runs eight custom HIP benchmarks that measure:
    - FP64 (double-precision floating point)
    - FP32 (single-precision floating point)
    - FP16 (half-precision floating point)
    - Simulated FP8 (8-bit floating point)
    - INT8 (8-bit integer arithmetic)
    - Memory throughput (memclock)
    - Compute performance (coreclock)
    
  - All benchmark outputs are consolidated into a single log file stored under `~/rocm_benchmarks/logs/`.

## Prerequisites

- **Operating System:** Ubuntu 22.04 (or similar)
- **Hardware:** AMD MI50 GPU (16 GB)
- **ROCm 5.7:** The script installs ROCm 5.7 along with HIP.
- **Build Tools:** The script installs `build-essential` and other necessary packages.
- **Network Access:** Required to download packages, ROCm installers, and Docker images.

## Installation

1. **Clone the Repository:**

   ```bash
   git clone https://github.com/slydcloud/mi50-server-setup-benchmarks.git
   cd mi50-server-setup-benchmarks

Ensure the Script is Executable:

bash

chmod +x full_setup_and_benchmark.sh

Usage
Run the script as your normal user (do not use sudo):

bash

./full_setup_and_benchmark.sh

The script will perform the following:

Server Configuration:
It updates your system, installs required packages, configures ROCm/HIP, sets up a Python virtual environment with PyTorch, and installs Docker. It also verifies your setup using rocminfo, rocm-smi, and a Docker container test that runs a simple PyTorch script.

Benchmarking:

Standard Benchmarks:
Stress-ng, sysbench, mbw, ROCm Bandwidth Test (executed from /opt/rocm-5.7.1/rocm-bandwidth-test/build), and a PyTorch GEMM test are run sequentially with output appended to a log file.
Custom HIP Benchmarks:
The script creates a subdirectory (~/rocm_benchmarks/custom_hip), writes eight HIP source files, compiles them using hipcc with additional flags for C++ standard library paths, and runs them.
Log File:
All outputs from the benchmarking tests (both standard and custom HIP benchmarks) are saved to a single log file under ~/rocm_benchmarks/logs/ with a timestamp in its filename.

Log File Retrieval
cat ~/rocm_benchmarks/logs/benchmark_run_YYYYMMDD_HHMMSS.log

Troubleshooting
Standard C++ Headers Not Found:
If you encounter issues with missing C++ headers when compiling HIP code, ensure that the required include paths (/usr/include/c++/9 and /usr/include/x86_64-linux-gnu/c++/9) and the library path (/usr/lib/gcc/x86_64-linux-gnu/9) are correctly specified. The script already includes these flags in the compilation commands.

Permissions Issues with Stress-ng:
The script uses the --temp-path /tmp flag for stress-ng to ensure that temporary files are written to a writable directory.

Reboot Requirements:
Some steps (like modifying GRUB or installing ROCm) may require a reboot. The script will prompt you to reboot if necessary. Re-run the script after rebooting.

Additional Notes
Customization:
You can modify the parameters (e.g., problem sizes, loop counts) in the HIP source files if you need to fine-tune the benchmarks for your specific hardware.

Environment:
It is recommended to run this script on a dedicated server instance to avoid interference with other workloads.

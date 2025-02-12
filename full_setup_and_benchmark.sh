#!/bin/bash
# full_setup_and_benchmark.sh
#
# This script fully configures the server (ROCm, HIP, PyTorch, Docker, etc.) and then runs a comprehensive
# suite of benchmarks. The benchmarks include:
#   - Stress tests: stress-ng (CPU and Memory), sysbench (CPU and Memory), mbw,
#     ROCm Bandwidth Test (run from its build folder), and a PyTorch GEMM test.
#   - Custom HIP benchmarks: testing FP64, FP32, FP16, simulated FP8, INT8, simulated INT7,
#     memory throughput (memclock), and compute performance (coreclock).
#
# All benchmark outputs are combined into a single log file.
#
# Usage:
#   chmod +x full_setup_and_benchmark.sh
#   ./full_setup_and_benchmark.sh
#
# (Run this as your normal user; do not use sudo.)

set -e

#####################################
# 1. Server Configuration Section
#####################################

STATE_DIR="$HOME/setup_state"
mkdir -p "$STATE_DIR"

echo "=== Preliminary Setup: Updating and Installing Packages ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y nano wget curl build-essential python3.10-venv stress-ng sysbench mbw

echo "=== Step 1: Installing Kernel Headers ==="
if [ ! -f "$STATE_DIR/step1_done" ]; then
  sudo apt install -y linux-headers-$(uname -r)
  touch "$STATE_DIR/step1_done"
else
  echo "Kernel headers already installed. Skipping."
fi

echo "=== Step 1.3: Checking GRUB for iommu=pt ==="
if [ ! -f "$STATE_DIR/step1_3_done" ]; then
  if grep -q "iommu=pt" /etc/default/grub; then
      echo "iommu=pt already set in GRUB."
  else
      echo "iommu=pt not set. Updating GRUB..."
      sudo sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="iommu=pt /' /etc/default/grub
      sudo update-grub
      echo "GRUB updated. Reboot required."
      touch "$STATE_DIR/step1_3_done_pending"
      echo "Please reboot and re-run the script. Exiting now."
      exit 0
  fi
  touch "$STATE_DIR/step1_3_done"
else
  echo "GRUB configuration already done. Skipping."
fi

echo "=== Step 2: Cleaning Up Previous ROCm Installations ==="
if [ ! -f "$STATE_DIR/step2_done" ]; then
  sudo amdgpu-install --uninstall 2>/dev/null || echo "No previous installation found."
  sudo apt purge -y 'rocm-*' 'hip-*' 'hsa-*' 'amdgpu-*' || true
  sudo apt autoremove -y || true
  sudo rm -f /etc/apt/sources.list.d/rocm*.list /etc/apt/sources.list.d/amdgpu*.list
  sudo apt update
  sudo rm -rf /opt/rocm-*
  touch "$STATE_DIR/step2_done"
else
  echo "Cleanup already done. Skipping."
fi

echo "=== Step 3: Installing ROCm 5.7 with HIP ==="
if [ -f "$STATE_DIR/step3_done_pending" ]; then
  rm -f "$STATE_DIR/step3_done_pending"
  touch "$STATE_DIR/step3_done"
elif [ ! -f "$STATE_DIR/step3_done" ]; then
  wget -qO amdgpu-install.deb https://repo.radeon.com/amdgpu-install/5.7.1/ubuntu/jammy/amdgpu-install_5.7.50701-1_all.deb
  sudo dpkg -i amdgpu-install.deb
  sudo apt update
  sudo amdgpu-install --usecase=rocm,hip --accept-eula
  echo "ROCm installed. Reboot required to load new modules."
  touch "$STATE_DIR/step3_done_pending"
  read -p "Reboot now? [y/N] " answer
  if [[ $answer =~ ^[Yy]$ ]]; then
      sudo reboot
      exit 0
  else
      rm -f "$STATE_DIR/step3_done_pending"
      touch "$STATE_DIR/step3_done"
  fi
else
  echo "ROCm already installed. Skipping."
fi

echo "=== Step 3.5: Adding User to Groups (video, render) ==="
if [ ! -f "$STATE_DIR/step3_5_done" ]; then
  sudo usermod -aG video $USER
  if getent group render >/dev/null; then
      sudo usermod -aG render $USER
  else
      echo "Group 'render' not found. Skipping render group."
  fi
  touch "$STATE_DIR/step3_5_done"
  echo "Please log out/in (or reboot) to apply group changes."
  read -p "Press Enter to continue after re-logging in..."
else
  echo "User groups already set. Skipping."
fi

echo "=== Step 4: Verifying ROCm Installation ==="
if [ ! -f "$STATE_DIR/step4_done" ]; then
  echo "Running rocminfo..."
  rocminfo | grep -A20 "Agent 0" || rocminfo
  echo "Running rocm-smi..."
  rocm-smi
  echo "HIP Compiler Version:"
  hipcc --version
  echo "Kernel command line (iommu info):"
  cat /proc/cmdline | grep iommu
  touch "$STATE_DIR/step4_done"
fi

echo "=== Step 5: Setting Up Python Virtual Environment and Installing PyTorch ==="
if [ ! -f "$STATE_DIR/step5_done" ]; then
  rm -rf ~/rocm5.7-env
  python3 -m venv --copies ~/rocm5.7-env
  source ~/rocm5.7-env/bin/activate
  pip install --upgrade pip setuptools wheel
  pip install "numpy<2"
  pip install torch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2 --index-url https://download.pytorch.org/whl/rocm5.7
  python -c "import torch; print('Torch version:', torch.__version__)"
  deactivate
  touch "$STATE_DIR/step5_done"
fi

echo "=== Step 6: Installing Docker Engine ==="
if [ ! -f "$STATE_DIR/step6_docker_done" ]; then
  if ! command -v docker >/dev/null 2>&1; then
      sudo apt update
      sudo apt install -y docker.io
      sudo systemctl enable --now docker
  else
      echo "Docker already installed."
  fi
  sudo usermod -aG docker $USER
  echo "Added user $USER to docker group. Please log out/in (or run 'newgrp docker')."
  read -p "Press Enter to continue after re-logging in..."
  touch "$STATE_DIR/step6_docker_done"
fi

echo "=== Step 7: Building Minimal Docker Image ==="
if [ ! -f "$STATE_DIR/step7_done" ]; then
  for i in {1..10}; do
      if docker info >/dev/null 2>&1; then
          echo "Docker daemon is accessible."
          break
      fi
      echo "Waiting for Docker daemon..."
      sleep 10
  done
  mkdir -p ~/myrocm-docker
  cat > ~/myrocm-docker/Dockerfile << 'EOF'
FROM ubuntu:22.04
RUN apt update && apt install -y libnuma1 libexpat1 python3.10 python3.10-minimal
ENTRYPOINT ["/bin/bash"]
EOF
  cd ~/myrocm-docker
  docker build -t myrocm-base .
  touch "$STATE_DIR/step7_done"
fi

echo "=== Step 7.5: Creating PyTorch Verification Script ==="
if [ ! -f "$HOME/check_pytorch.py" ]; then
  cat > "$HOME/check_pytorch.py" << 'EOF'
import torch
print("Torch version:", torch.__version__)
print("HIP version:", torch.version.hip)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("Device count:", torch.cuda.device_count())
    print("Device 0 name:", torch.cuda.get_device_name(0))
EOF
fi

echo "=== Step 8: Running Docker Container Test ==="
docker run -it --rm \
  --device=/dev/kfd --device=/dev/dri \
  --group-add video \
  -v /opt/rocm:/opt/rocm:ro \
  -v /home/$USER/rocm5.7-env:/venv \
  -v /home/$USER:/host_home \
  myrocm-base \
  -c "/venv/bin/python /host_home/check_pytorch.py || /venv/bin/python -c \"import torch; print('Torch version:', torch.__version__)\""

echo "=== Final Host Instructions ==="
echo "Host testing: Activate the venv with 'source ~/rocm5.7-env/bin/activate' and run 'python ~/check_pytorch.py'"
echo "Docker testing: Check container output above."
echo "Server configuration complete."

#####################################
# 2. Benchmarking Section
#####################################
echo "=== Starting Benchmark Suite ==="
BENCH_LOG_DIR="$HOME/rocm_benchmarks/logs"
mkdir -p "$BENCH_LOG_DIR"
BENCH_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BENCH_LOG_FILE="$BENCH_LOG_DIR/benchmark_run_${BENCH_TIMESTAMP}.log"
echo "Benchmark Run Started: $(date)" | tee "$BENCH_LOG_FILE"
echo "Logs will be saved to: $BENCH_LOG_FILE" | tee -a "$BENCH_LOG_FILE"
echo "======================================================" | tee -a "$BENCH_LOG_FILE"
echo "" | tee -a "$BENCH_LOG_FILE"

echo "=== Running Stress-ng CPU Test (8 workers, 60 seconds) ===" | tee -a "$BENCH_LOG_FILE"
stress-ng --cpu 8 --timeout 60s --temp-path /tmp | tee -a "$BENCH_LOG_FILE"
echo "" | tee -a "$BENCH_LOG_FILE"

echo "=== Running Stress-ng Memory Test (2 workers, 75% memory, 60 seconds) ===" | tee -a "$BENCH_LOG_FILE"
stress-ng --vm 2 --vm-bytes 75% --timeout 60s --temp-path /tmp | tee -a "$BENCH_LOG_FILE"
echo "" | tee -a "$BENCH_LOG_FILE"

echo "=== Running Sysbench CPU Test (cpu-max-prime=20000) ===" | tee -a "$BENCH_LOG_FILE"
sysbench cpu --cpu-max-prime=20000 run | tee -a "$BENCH_LOG_FILE"
echo "" | tee -a "$BENCH_LOG_FILE"

echo "=== Running Sysbench Memory Test ===" | tee -a "$BENCH_LOG_FILE"
sysbench memory run | tee -a "$BENCH_LOG_FILE"
echo "" | tee -a "$BENCH_LOG_FILE"

echo "=== Running MBW Memory Bandwidth Test (128 MB) ===" | tee -a "$BENCH_LOG_FILE"
mbw 128 | tee -a "$BENCH_LOG_FILE"
echo "" | tee -a "$BENCH_LOG_FILE"

echo "=== Running ROCm Bandwidth Test (Unidirectional All Devices Test) ===" | tee -a "$BENCH_LOG_FILE"
if [ -d "/opt/rocm-5.7.1/rocm-bandwidth-test/build" ]; then
  pushd /opt/rocm-5.7.1/rocm-bandwidth-test/build > /dev/null
  ./rocm-bandwidth-test -a | tee -a "$BENCH_LOG_FILE"
  popd > /dev/null
else
  echo "ROCm Bandwidth Test build directory not found. Skipping." | tee -a "$BENCH_LOG_FILE"
fi
echo "" | tee -a "$BENCH_LOG_FILE"

echo "=== Running PyTorch GEMM Benchmark ===" | tee -a "$BENCH_LOG_FILE"
~/rocm5.7-env/bin/python -c "import torch; A=torch.randn(1024,1024,device='hip'); B=torch.randn(1024,1024,device='hip'); torch.cuda.synchronize(); import time; start=time.time(); C=torch.mm(A,B); torch.cuda.synchronize(); print('GEMM Time:', time.time()-start)" | tee -a "$BENCH_LOG_FILE"
echo "" | tee -a "$BENCH_LOG_FILE"

#####################################
# 3. Custom HIP Benchmarking Section
#####################################
echo "=== Starting Custom HIP Benchmarks ===" | tee -a "$BENCH_LOG_FILE"
HIP_BENCH_DIR="$HOME/rocm_benchmarks/custom_hip"
mkdir -p "$HIP_BENCH_DIR"
cd "$HIP_BENCH_DIR"

# Create custom HIP source files (8 benchmarks)

# FP64
cat > benchmark_fp64.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <iostream>
#include <chrono>
#define N (1024 * 1024 * 16)
#define THREADS_PER_BLOCK 256
__global__ void fp64_kernel(double *a, double *b, double *c, int n) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < n) {
    double x = a[idx];
    double y = b[idx];
    for (int i = 0; i < 100; i++) {
      x = x * y + 1.0;
    }
    c[idx] = x;
  }
}
int main() {
  int n = N;
  size_t size = n * sizeof(double);
  double *ha = new double[n], *hb = new double[n], *hc = new double[n];
  for (int i = 0; i < n; i++) { ha[i] = 1.0; hb[i] = 2.0; }
  double *da, *db, *dc;
  hipMalloc(&da, size); hipMalloc(&db, size); hipMalloc(&dc, size);
  hipMemcpy(da, ha, size, hipMemcpyHostToDevice);
  hipMemcpy(db, hb, size, hipMemcpyHostToDevice);
  int blocks = (n + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  auto start = std::chrono::high_resolution_clock::now();
  hipLaunchKernelGGL(fp64_kernel, dim3(blocks), dim3(THREADS_PER_BLOCK), 0, 0, da, db, dc, n);
  hipDeviceSynchronize();
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> elapsed = end - start;
  std::cout << "Custom FP64 kernel time: " << elapsed.count() << " seconds" << std::endl;
  hipMemcpy(hc, dc, size, hipMemcpyDeviceToHost);
  std::cout << "Custom FP64 sample result: " << hc[0] << std::endl;
  hipFree(da); hipFree(db); hipFree(dc);
  delete[] ha; delete[] hb; delete[] hc;
  return 0;
}
EOF

# FP32
cat > benchmark_fp32.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <iostream>
#include <chrono>
#define N (1024 * 1024 * 16)
#define THREADS_PER_BLOCK 256
__global__ void fp32_kernel(float *a, float *b, float *c, int n) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < n) {
    float x = a[idx];
    float y = b[idx];
    for (int i = 0; i < 100; i++) {
      x = x * y + 1.0f;
    }
    c[idx] = x;
  }
}
int main() {
  int n = N;
  size_t size = n * sizeof(float);
  float *ha = new float[n], *hb = new float[n], *hc = new float[n];
  for (int i = 0; i < n; i++) { ha[i] = 1.0f; hb[i] = 2.0f; }
  float *da, *db, *dc;
  hipMalloc(&da, size); hipMalloc(&db, size); hipMalloc(&dc, size);
  hipMemcpy(da, ha, size, hipMemcpyHostToDevice);
  hipMemcpy(db, hb, size, hipMemcpyHostToDevice);
  int blocks = (n + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  auto start = std::chrono::high_resolution_clock::now();
  hipLaunchKernelGGL(fp32_kernel, dim3(blocks), dim3(THREADS_PER_BLOCK), 0, 0, da, db, dc, n);
  hipDeviceSynchronize();
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> elapsed = end - start;
  std::cout << "Custom FP32 kernel time: " << elapsed.count() << " seconds" << std::endl;
  hipMemcpy(hc, dc, size, hipMemcpyDeviceToHost);
  std::cout << "Custom FP32 sample result: " << hc[0] << std::endl;
  hipFree(da); hipFree(db); hipFree(dc);
  delete[] ha; delete[] hb; delete[] hc;
  return 0;
}
EOF

# FP16
cat > benchmark_fp16.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <hip/hip_fp16.h>
#include <iostream>
#include <chrono>
#define N (1024 * 1024 * 16)
#define THREADS_PER_BLOCK 256
__global__ void fp16_kernel(__half *a, __half *b, __half *c, int n) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < n) {
    __half x = a[idx];
    __half y = b[idx];
    for (int i = 0; i < 100; i++) {
      x = __hadd(__hmul(x, y), __float2half(1.0f));
    }
    c[idx] = x;
  }
}
int main() {
  int n = N;
  size_t size = n * sizeof(__half);
  __half *ha = new __half[n], *hb = new __half[n], *hc = new __half[n];
  for (int i = 0; i < n; i++) { ha[i] = __float2half(1.0f); hb[i] = __float2half(2.0f); }
  __half *da, *db, *dc;
  hipMalloc(&da, size); hipMalloc(&db, size); hipMalloc(&dc, size);
  hipMemcpy(da, ha, size, hipMemcpyHostToDevice);
  hipMemcpy(db, hb, size, hipMemcpyHostToDevice);
  int blocks = (n + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  auto start = std::chrono::high_resolution_clock::now();
  hipLaunchKernelGGL(fp16_kernel, dim3(blocks), dim3(THREADS_PER_BLOCK), 0, 0, da, db, dc, n);
  hipDeviceSynchronize();
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> elapsed = end - start;
  std::cout << "Custom FP16 kernel time: " << elapsed.count() << " seconds" << std::endl;
  hipMemcpy(hc, dc, size, hipMemcpyDeviceToHost);
  std::cout << "Custom FP16 sample result (as float): " << __half2float(hc[0]) << std::endl;
  hipFree(da); hipFree(db); hipFree(dc);
  delete[] ha; delete[] hb; delete[] hc;
  return 0;
}
EOF

# FP8 (Simulated FP8)
cat > benchmark_fp8.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <iostream>
#include <chrono>
#include <algorithm>
#define N (1024 * 1024 * 16)
#define THREADS_PER_BLOCK 256
__global__ void fp8_kernel(unsigned char *a, unsigned char *b, unsigned char *c, int n) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < n) {
    float x = ((float)a[idx]) / 255.0f;
    float y = ((float)b[idx]) / 255.0f;
    for (int i = 0; i < 100; i++) {
      x = x * y + (1.0f/255.0f);
    }
    c[idx] = (unsigned char)(fminf(fmaxf(x * 255.0f, 0.0f), 255.0f));
  }
}
int main() {
  int n = N;
  size_t size = n * sizeof(unsigned char);
  unsigned char *ha = new unsigned char[n], *hb = new unsigned char[n], *hc = new unsigned char[n];
  for (int i = 0; i < n; i++) { ha[i] = 1; hb[i] = 2; }
  unsigned char *da, *db, *dc;
  hipMalloc(&da, size); hipMalloc(&db, size); hipMalloc(&dc, size);
  hipMemcpy(da, ha, size, hipMemcpyHostToDevice);
  hipMemcpy(db, hb, size, hipMemcpyHostToDevice);
  int blocks = (n + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  auto start = std::chrono::high_resolution_clock::now();
  hipLaunchKernelGGL(fp8_kernel, dim3(blocks), dim3(THREADS_PER_BLOCK), 0, 0, da, db, dc, n);
  hipDeviceSynchronize();
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> elapsed = end - start;
  std::cout << "Custom FP8 kernel time: " << elapsed.count() << " seconds" << std::endl;
  hipMemcpy(hc, dc, size, hipMemcpyDeviceToHost);
  std::cout << "Custom FP8 sample result: " << (int)hc[0] << std::endl;
  hipFree(da); hipFree(db); hipFree(dc);
  delete[] ha; delete[] hb; delete[] hc;
  return 0;
}
EOF

# INT8
cat > benchmark_int8.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <iostream>
#include <chrono>
#include <stdint.h>
#define N (1024 * 1024 * 16)
#define THREADS_PER_BLOCK 256
__global__ void int8_kernel(uint8_t *a, uint8_t *b, uint8_t *c, int n) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < n) {
    uint8_t x = a[idx];
    uint8_t y = b[idx];
    for (int i = 0; i < 100; i++) {
      x = x * y + 1;
    }
    c[idx] = x;
  }
}
int main() {
  int n = N;
  size_t size = n * sizeof(uint8_t);
  uint8_t *ha = new uint8_t[n], *hb = new uint8_t[n], *hc = new uint8_t[n];
  for (int i = 0; i < n; i++) { ha[i] = 1; hb[i] = 2; }
  uint8_t *da, *db, *dc;
  hipMalloc(&da, size); hipMalloc(&db, size); hipMalloc(&dc, size);
  hipMemcpy(da, ha, size, hipMemcpyHostToDevice);
  hipMemcpy(db, hb, size, hipMemcpyHostToDevice);
  int blocks = (n + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  auto start = std::chrono::high_resolution_clock::now();
  hipLaunchKernelGGL(int8_kernel, dim3(blocks), dim3(THREADS_PER_BLOCK), 0, 0, da, db, dc, n);
  hipDeviceSynchronize();
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> elapsed = end - start;
  std::cout << "Custom INT8 kernel time: " << elapsed.count() << " seconds" << std::endl;
  hipMemcpy(hc, dc, size, hipMemcpyDeviceToHost);
  std::cout << "Custom INT8 sample result: " << (int)hc[0] << std::endl;
  hipFree(da); hipFree(db); hipFree(dc);
  delete[] ha; delete[] hb; delete[] hc;
  return 0;
}
EOF

# INT7
cat > benchmark_int7.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <iostream>
#include <chrono>
#include <stdint.h>
#define N (1024 * 1024 * 16)
#define THREADS_PER_BLOCK 256
// Simulate 7-bit arithmetic by masking to 7 bits (0x7F)
__global__ void int7_kernel(uint8_t *a, uint8_t *b, uint8_t *c, int n) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < n) {
    uint8_t x = a[idx] & 0x7F;
    uint8_t y = b[idx] & 0x7F;
    for (int i = 0; i < 100; i++) {
      x = ((x * y) + 1) & 0x7F;
    }
    c[idx] = x;
  }
}
int main() {
  int n = N;
  size_t size = n * sizeof(uint8_t);
  uint8_t *ha = new uint8_t[n], *hb = new uint8_t[n], *hc = new uint8_t[n];
  for (int i = 0; i < n; i++) { ha[i] = 1; hb[i] = 2; }
  uint8_t *da, *db, *dc;
  hipMalloc(&da, size); hipMalloc(&db, size); hipMalloc(&dc, size);
  hipMemcpy(da, ha, size, hipMemcpyHostToDevice);
  hipMemcpy(db, hb, size, hipMemcpyHostToDevice);
  int blocks = (n + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  auto start = std::chrono::high_resolution_clock::now();
  hipLaunchKernelGGL(int7_kernel, dim3(blocks), dim3(THREADS_PER_BLOCK), 0, 0, da, db, dc, n);
  hipDeviceSynchronize();
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> elapsed = end - start;
  std::cout << "Custom INT7 kernel time: " << elapsed.count() << " seconds" << std::endl;
  hipMemcpy(hc, dc, size, hipMemcpyDeviceToHost);
  std::cout << "Custom INT7 sample result: " << (int)hc[0] << std::endl;
  hipFree(da); hipFree(db); hipFree(dc);
  delete[] ha; delete[] hb; delete[] hc;
  return 0;
}
EOF

# Memclock
cat > benchmark_memclock.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <iostream>
#include <chrono>
#define N (1024 * 1024 * 256)
#define THREADS_PER_BLOCK 256
__global__ void memcopy_kernel(float *in, float *out, int n) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < n) {
    out[idx] = in[idx];
  }
}
int main() {
  int n = N;
  size_t size = n * sizeof(float);
  float *h_in = new float[n], *h_out = new float[n];
  for (int i = 0; i < n; i++) { h_in[i] = 1.0f; }
  float *d_in, *d_out;
  hipMalloc(&d_in, size); hipMalloc(&d_out, size);
  hipMemcpy(d_in, h_in, size, hipMemcpyHostToDevice);
  int blocks = (n + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  auto start = std::chrono::high_resolution_clock::now();
  hipLaunchKernelGGL(memcopy_kernel, dim3(blocks), dim3(THREADS_PER_BLOCK), 0, 0, d_in, d_out, n);
  hipDeviceSynchronize();
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> elapsed = end - start;
  double bandwidth = size / (elapsed.count() * 1e9);
  std::cout << "Memory Copy Kernel time: " << elapsed.count() << " seconds" << std::endl;
  std::cout << "Effective Memory Bandwidth: " << bandwidth << " GB/s" << std::endl;
  hipMemcpy(h_out, d_out, size, hipMemcpyDeviceToHost);
  hipFree(d_in); hipFree(d_out);
  delete[] h_in; delete[] h_out;
  return 0;
}
EOF

# Coreclock
cat > benchmark_coreclock.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <iostream>
#include <chrono>
#define N (1024 * 1024 * 16)
#define THREADS_PER_BLOCK 256
__global__ void compute_kernel(float *data, int n) {
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < n) {
    float x = data[idx];
    for (int i = 0; i < 1000; i++) {
      x = x * 1.000001f + 0.000001f;
    }
    data[idx] = x;
  }
}
int main() {
  int n = N;
  size_t size = n * sizeof(float);
  float *h_data = new float[n];
  for (int i = 0; i < n; i++) { h_data[i] = 1.0f; }
  float *d_data;
  hipMalloc(&d_data, size);
  hipMemcpy(d_data, h_data, size, hipMemcpyHostToDevice);
  int blocks = (n + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  auto start = std::chrono::high_resolution_clock::now();
  hipLaunchKernelGGL(compute_kernel, dim3(blocks), dim3(THREADS_PER_BLOCK), 0, 0, d_data, n);
  hipDeviceSynchronize();
  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> elapsed = end - start;
  std::cout << "Compute Kernel time: " << elapsed.count() << " seconds" << std::endl;
  hipMemcpy(h_data, d_data, size, hipMemcpyDeviceToHost);
  std::cout << "Sample result: " << h_data[0] << std::endl;
  hipFree(d_data);
  delete[] h_data;
  return 0;
}
EOF

echo "Created all custom HIP source files in $HIP_BENCH_DIR."

# Define common hipcc flags for custom HIP benchmarks
COMMON_FLAGS="-isystem /usr/include/c++/9 -isystem /usr/include/x86_64-linux-gnu/c++/9 -L/usr/lib/gcc/x86_64-linux-gnu/9 -lstdc++ -O3"

echo "=== Compiling Custom HIP Benchmarks ===" | tee -a "$BENCH_LOG_FILE"
declare -a custom_sources=("benchmark_fp64.cpp" "benchmark_fp32.cpp" "benchmark_fp16.cpp" "benchmark_fp8.cpp" "benchmark_int8.cpp" "benchmark_int7.cpp" "benchmark_memclock.cpp" "benchmark_coreclock.cpp")
declare -a custom_exes=("benchmark_fp64" "benchmark_fp32" "benchmark_fp16" "benchmark_fp8" "benchmark_int8" "benchmark_int7" "benchmark_memclock" "benchmark_coreclock")
for i in "${!custom_sources[@]}"; do
    src=${custom_sources[$i]}
    exe=${custom_exes[$i]}
    echo "Compiling custom HIP benchmark $src ..." | tee -a "$BENCH_LOG_FILE"
    hipcc $COMMON_FLAGS -o "$exe" "$src" >> "$BENCH_LOG_FILE" 2>&1
done
echo "Custom HIP benchmarks compilation complete." | tee -a "$BENCH_LOG_FILE"

echo "=== Running Custom HIP Benchmarks ===" | tee -a "$BENCH_LOG_FILE"
for exe in "${custom_exes[@]}"; do
    echo "===== Running custom HIP benchmark $exe =====" | tee -a "$BENCH_LOG_FILE"
    ./"$exe" 2>&1 | tee -a "$BENCH_LOG_FILE"
    echo "" | tee -a "$BENCH_LOG_FILE"
done
echo "Custom HIP benchmarks completed." | tee -a "$BENCH_LOG_FILE"

echo "All benchmark tests completed at $(date)." | tee -a "$BENCH_LOG_FILE"
echo "All logs have been saved to $BENCH_LOG_FILE."

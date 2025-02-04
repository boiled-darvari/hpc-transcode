# hpc-transcode

High-performance distributed video transcoding with CPU/GPU support

## Features

- Distributed transcoding across multiple nodes using SSH
- CPU and GPU (NVIDIA CUDA) support 
- Multi-resolution output (e.g. 240p, 480p, 720p)
- Audio track preservation
- HLS output support
- Segment-based processing

## Usage

```bash
Usage: gpff.bash [options]

Options:
  -d | --work-dir <path>          Set working directory (default: /mnt/data/)
  -i | --input <file>             Input file (must be .mkv or .mp4)
  -b | --ffmpeg-bin-dir <path>    Directory containing ffmpeg binaries
  -l | --local-only               Run locally only
  -g | --with-gpu                 Use GPU acceleration
  -r | --resolutions <list>       Comma-separated resolutions (default: 240,480,720)
  -a | --audio-duration <secs>    Audio segment duration (default: 600)
  -v | --video-duration <secs>    Video segment duration (default: 60)
  -s | --hls-duration <secs>      HLS segment duration (default: 10)

Examples:
  # Basic distributed CPU transcoding
  gpff.bash -i video.mkv

  # Local CPU transcoding
  gpff.bash -i video.mkv -l

  # Custom resolutions
  gpff.bash -i video.mkv -r 480,720,1080

  # GPU acceleration with custom work directory
  gpff.bash -i video.mkv -g -d /path/to/work
```

> **Tip:** Always run inside `tmux` for long transcoding jobs inside the servers

## Requirements 

### Master Node
- FFmpeg with CUDA filters (for GPU mode)
- GNU Parallel (only needed on master)
- OpenSSH Client
- tmux (recommended)

### Worker Nodes
- FFmpeg with same version and capabilities as master
- OpenSSH Server
- NVIDIA drivers & CUDA (if using GPU)

### Important Notes
- Package manager FFmpeg versions usually lack CUDA support
- All nodes must be able to access the same work directory path
- FFmpeg versions should match across all nodes
- Worker nodes don't need GNU Parallel installed

## Setup Guide

### 1. Master Node Setup
```bash
# Install required packages
sudo apt install ffmpeg parallel tmux openssh-client     # Debian/Ubuntu
sudo dnf install ffmpeg parallel tmux openssh-clients    # RHEL/Fedora
```

### 2. Worker Node Setup
```bash
# Install only required packages
sudo apt install ffmpeg openssh-server     # Debian/Ubuntu
sudo dnf install ffmpeg openssh-server     # RHEL/Fedora

# For GPU support (if needed)
sudo apt install nvidia-cuda-toolkit      # Debian/Ubuntu
sudo dnf install cuda-toolkit             # RHEL/Fedora
```

### 3. Distributed Configuration

#### A. SSH Setup
1. Generate key on master:
```bash
ssh-keygen -t ed25519 -C "transcode-cluster"
```

2. Copy to workers:
```bash
ssh-copy-id user@worker1
ssh-copy-id user@worker2
```

#### B. GNU Parallel Setup
Only on master node:
```bash
# Acknowledge citation
parallel --will-cite

# Create configuration
echo "user@worker1" >> ~/.parallel/sshloginfile
echo "user@worker2" >> ~/.parallel/sshloginfile

```

#### C. Storage Setup
On all nodes:
```bash
sudo mkdir -p /mnt/data
sudo mount /dev/nvme0n1 /mnt/data    # Example for NVMe drive
```

#### D. FFmpeg Setup
1. Download FFmpeg (all nodes need compatible versions):
    - [Official static builds](https://ffmpeg.org/download.html#build-linux) with CUDA
    - [BtbN's builds](https://github.com/BtbN/FFmpeg-Builds/releases) with CUDA support like `gpl`
    - [Custom built FFmpeg](https://trac.ffmpeg.org/wiki/CompilationGuide/Ubuntu#CUDA) with CUDA support

Note: Package manager versions of FFmpeg typically lack CUDA support.

2. Verify installation on all nodes:
```bash
ffmpeg -version
```

### 4. Testing

```bash
# Test master node setup
parallel --will-cite echo ::: "Parallel works!"
ffmpeg -version

# Check CUDA support
ffmpeg -hide_banner -filters | grep cuda

# Test worker node connectivity
parallel --nonall -S '..' hostname

# Test FFmpeg on workers
parallel --nonall -S '..' ffmpeg -version

# Test GPU if using
parallel --nonall -S '..' 'nvidia-smi && echo "GPU OK"'

# Test CUDA support in FFmpeg if using GPU
parallel --nonall -S '..' 'ffmpeg -hide_banner -filters | grep -q "scale_cuda" && echo "CUDA OK"'
```

## Advanced Configuration

### Performance Tuning
```bash
# Audio segment duration (default: 600s)
gpff.bash -i video.mkv -a 300

# Video segment duration (default: 60s)
gpff.bash -i video.mkv -v 30

# Custom resolutions
gpff.bash -i video.mkv -r 360,720,1080
```

### Output Formats
- Individual resolution MP4/MKV files
- HLS playlist with all resolutions
- Preserved audio tracks
- Original video container format maintained

## Troubleshooting

### Common Issues
1. GPU mode fails:
   - Check FFmpeg has CUDA filters
   - Verify NVIDIA drivers on all nodes
   - Ensure matching FFmpeg versions

2. Node connectivity:
   - Check ~/.parallel/sshloginfile format
   - Verify SSH keys are properly set up
   - Test work directory exists and is writable

3. Audio sync:
   - Adjust segment durations if needed
   - Keep original container format
   - Use -fps_mode passthrough (default)

## Usage Notes

- Tested with:
  - FFmpeg builds: [`ffmpeg-n7.1-latest-linux64-gpl-7.1`](https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-linux64-gpl-7.1.tar.xz) and [RPM Fusion](https://koji.rpmfusion.org/koji/buildinfo?buildID=30044)  
  - Formats: MKV, MP4
- Temporary segments in master server can be preserved for debugging
- Requires same paths/permissions across nodes
- Currently a PoC (proof-of-concept) implementation


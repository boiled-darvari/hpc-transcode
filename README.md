# HPC-Transcode

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

  # GPU acceleration with SSD path and custom FFmpeg build
  gpff.bash -i "./Akira.1988.mkv" -g -d "/mnt/data/" -b "/mnt/data/ffmpeg-n7.1-latest-linux64-gpl-7.1/bin/ffmpeg/"
```

> **Tip:** Always run inside `tmux` for long transcoding jobs inside the servers

## Requirements & Setup

### Master Node
1. FFmpeg
   - CPU mode: Any recent build
   - GPU mode: Must have CUDA support ([see FFmpeg Setup](#ffmpeg-setup))
2. GNU Parallel ([Installation Guide](https://www.gnu.org/software/parallel/))
3. OpenSSH Client
4. tmux (recommended)

### Worker Nodes
1. FFmpeg (same version/capabilities as master)
2. OpenSSH Server
3. For GPU mode:
   - NVIDIA GPU
   - NVIDIA drivers
   - CUDA Toolkit
   - FFmpeg with CUDA support

### FFmpeg Setup
Choose one:
1. [BtbN's FFmpeg Builds](https://github.com/BtbN/FFmpeg-Builds/releases) (GPL with CUDA)
2. [Custom build with CUDA](https://trac.ffmpeg.org/wiki/CompilationGuide/Ubuntu#CUDA)
3. [Official static builds](https://ffmpeg.org/download.html#build-linux) (verify CUDA support)

> ⚠️ Package manager versions typically lack CUDA support

### Installation Steps
1. Install base packages:
```bash
# Master node (Debian/Ubuntu)
sudo apt install parallel tmux openssh-client   # Debian/Ubuntu

# Worker nodes
sudo apt install openssh-server                 # Debian/Ubuntu

# For GPU in Master and Workers: 
sudo apt install nvidia-cuda-toolkit            # Debian/Ubuntu
sudo dnf install cuda-toolkit                   # RHEL/Fedora
```

2. Setup SSH:
```bash
ssh-keygen -t ed25519 -C "transcode-cluster"
ssh-copy-id user@worker123
ssh-copy-id resu@1.2.3.4
```

3. Configure GNU Parallel (master only):
```bash
parallel --will-cite  # Acknowledge citation
echo "user@worker1" >> ~/.parallel/sshloginfile
echo "user@worker2" >> ~/.parallel/sshloginfile
echo "resu@1.2.3.4" >> ~/.parallel/sshloginfile
```

4. Prepare storage (all nodes):
```bash
sudo mkdir -p /mnt/data
sudo mount /dev/nvme0n1 /mnt/data    # Example for NVMe drive
```

## Verification

Test your setup:
```bash
# Basic connectivity
parallel --nonall -S '..' hostname

# FFmpeg availability & version
parallel --nonall -S '..' ffmpeg -version

# GPU support (if using)
parallel --nonall -S '..' '
    if command -v nvidia-smi >/dev/null; then
        echo "=== $(hostname) ==="
        nvidia-smi
        ffmpeg -hide_banner -filters | grep cuda
    fi
'
```

## Advanced Usage

### Performance Tuning
```bash
# Adjust segment durations
gpff.bash -i video.mkv -a 300 -v 30

# Custom resolutions
gpff.bash -i video.mkv -r 360,720,1080
```

### Output Types
- Resolution-specific files (MP4/MKV)
- HLS playlist with all qualities
- Original container format preserved
- All audio tracks included

## Troubleshooting

1. GPU Issues
   - Verify CUDA in FFmpeg: `ffmpeg -filters | grep cuda`
   - Check GPU access: `nvidia-smi`
   - Confirm matching FFmpeg versions

2. Node Issues
   - Test SSH access
   - Verify work directory exists
   - Check file permissions

3. Processing Issues
   - Segment duration adjustments
   - Audio sync (-fps_mode passthrough)
   - Work directory space

## Notes
- Tested: FFmpeg n7.1+ (GPL build)
- Formats: MKV, MP4
- POC implementation
- Subtitles are not handled in this script


# hpc-transcode
High-Performance Video Transcoding

![image](https://github.com/user-attachments/assets/8c02fbd9-9685-49d6-957c-f32d225fbcd7)

This script enables high-performance video transcoding using multiple nodes and GPU acceleration. It leverages the power of distributed computing and GPU resources to significantly speed up the transcoding process, making it ideal for large-scale video processing tasks.

## How to Use

To transcode a video file:

```bash
bash gpff.bash "filename.mkv"
```

To run locally:

```bash
bash gpff.bash "filename.mkv" true
```

To run locally with GPU:

```bash
bash gpff.bash "filename.mkv" true true
```

To run in parallel on all servers with GPU:

```bash
bash gpff.bash "filename.mkv" false true
```

*It's recommended to run inside `tmux`.*

## Preparations

1. Generate a new passwordless SSH key on the master server:
    ```bash
    ssh-keygen -t ed25519 -C "transcode-cluster"
    ```
2. Copy the SSH key to worker/slave servers:
    ```bash
    ssh-copy-id -i ~/.ssh/your_key_id user@worker-server
    ```
3. On the master server, add the worker server list to the `~/.parallel/sshloginfile` file if running in distributed mode:
    ```
    user@worker1,--ssh-key-id ~/.ssh/your_key_id
    user@worker2,--ssh-key-id ~/.ssh/your_key_id
    ```
4. Add an SSD drive/partition with the same path on all servers (e.g., `"/mnt/data/"`).
5. Update the `work_dir` value in `gpff.bash` based on the previous step.
6. Download FFmpeg from [here](https://ffmpeg.org/download.html) (download the `non-free` or `gpl` version).
7. Copy and extract FFmpeg to the `work_dir` path on all servers.
8. Update the `ffmpeg_binary` and `ffprobe_binary` values in `gpff.bash`.
9. Copy the `gpff.bash` file to the `work_dir` path.
10. Install required packages on servers that will process videos:
     ```bash
     # For Ubuntu/Debian
     sudo apt-get install parallel
     # For CentOS/RHEL
     sudo yum install parallel
     ```
11. Set up CUDA and GPU drivers if using GPU acceleration:
     ```bash
     # For Ubuntu/Debian
     sudo apt-get install nvidia-cuda-toolkit
     ```
12. If using GPU, ensure worker nodes can run `nvidia-smi` without password:
     ```bash
     # Add to /etc/sudoers
     username ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi
     ```

## Notes

- All segments will remain in the video's directory in case something goes wrong.
- Tested with MKV and MP4 files. Other formats may work as well.
- Tested with [`ffmpeg-n7.1-latest-linux64-gpl-7.1`](https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-linux64-gpl-7.1.tar.xz)
- Ensure `parallel` is installed on all servers for distributed processing.
- The `sudo` command is required only to install packages and set up GPU drivers.
- The `ssh-key-id` is necessary for passwordless SSH access between master and worker nodes in non-local jobs.
- Ensure all servers have the same directory structure and necessary permissions.


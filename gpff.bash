#!/bin/bash

# GNU Parallel + FFMPEG = gpff
VERSION="0.1.0-preview"

### preparations:
#
# - generate a new passwordless ssh-key on the master server
# - copy ssh-key-id to worker/slave servers
#
# - on the master server, add the worker server list to ~/.parallel/sshloginfile
# according to the --slf structure in the parallel man page
#
# - add an SSD drive/partition with the same path on all servers (e.g. "/mnt/data/")
# - change the work_dir value based on the previous step
#
# - download ffmpeg: https://ffmpeg.org/download.html
# - copy and extract to the work_dir path on all servers
# - change the ffmpeg_binary and ffprobe_binary values based on that
#
# - copy the bash file to the work_dir path
#
# - don't forget to install "parallel" if you don't have it already
#
# all are ready

# our color for just separating the sections.
cyanbg="\033[0;46m"
clear="\033[0m"

work_dir="/mnt/data/"

# here we choose between static build of ffmpeg and packages.
# ffmpeg_binary="./ffmpeg-n7.1-latest-linux64-gpl-7.1/bin/ffmpeg"
# ffmpeg_binary="/mnt/data/ffmpeg-git-20240504-amd64-static/ffmpeg"
ffmpeg_binary="ffmpeg"

# here we choose between static build of ffprobe and packages.
# ffprobe_binary="./ffmpeg-n7.1-latest-linux64-gpl-7.1/bin/ffprobe"
# ffprobe_binary="/mnt/data/ffmpeg-git-20240504-amd64-static/ffprobe"
ffprobe_binary="ffprobe"

# Default to distributed CPU mode
localonly="false"
withgpu="false"

resolutions=( "240" "480" "720" )

# the duration can be anything, but the smaller it goes, the more overhead we will have.
# also the bigger it goes, there is a chance that we will have the last file our bottleneck.
# so it should be not so long, not so short. 200 in seconds means 00:03:20
audio_segments_duration=600
video_segments_duration=60

# The duration when we're doing HLS. Note that in some cases the keyframes interval was 10 seconds!
hls_duration=10


input_file=""
input_extension=""
input_filename=""

function parse_filename(){
    # analyzing the input and changing the spaces in the name to dashes
    # to avoid potential bugs
    local input_temp_name="$1"
    local input_corrected_name=$(echo "$input_temp_name" | sed 's/[]_[ ]/\-/g')
    if [[ "$input_temp_name" != "$input_corrected_name" ]]; then
        mv "$input_temp_name" "$input_corrected_name"
    fi

    input_file="$input_corrected_name"
    input_extension=".${input_file##*.}"
    input_filename="${input_file%.*}"

    # do we want to transcode only mkv and mp4 files?
    if [[ "$input_extension" != ".mkv" ]] && [[ "$input_extension" != ".mp4" ]] ; then
        echo "Please provide a .mkv or .mp4 file"
        exit 1
    fi
}

function parse_resolutions() {
    local input_list="$1"
    IFS=',' read -r -a resolutions_array <<< "$input_list"
    resolutions=("${resolutions_array[@]}")
    # for resolution in "${resolutions[@]}"; do
    #     echo "$resolution"
    # done
}

function log() {
    echo "$@" 1>&2
}

function checking() {
    log -n "checking $@... "
}

function fatal() {
    log "$@"
    exit 1
}

function require() {
    checking "for $1"
    if ! [ -x "$(command -v $1)" ]; then
        fatal "not found; please $2"
    fi
    log "ok"
}

function parse_ffmpeg_binary() {
    ffmpeg_binary="${1}ffmpeg"
    ffprobe_binary="${1}ffprobe"
    require "$ffmpeg_binary" "follow setup instructions for ffmpeg, $ffmpeg_binary is not executable"
    require "$ffprobe_binary" "follow setup instructions for ffmpeg, $ffprobe_binary is not executable"
}

function usage()
{
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -d | --work-dir <path>          Set the working directory (default: /mnt/data/)"
    echo "  -i | --input <file>             Set the input file (must be .mkv or .mp4)"
    echo "  -b | --ffmpeg-bin-dir <path>    Set the directory containing ffmpeg and ffprobe binaries"
    echo "  -l | --local-only               Run the script locally only"
    echo "  -g | --with-gpu                 Use GPU for transcoding"
    echo "  -r | --resolutions <list>       Comma-separated list of resolutions (default: 240,480,720)"
    echo "  -a | --audio-duration <seconds> Set the duration for audio segments (default: 600)"
    echo "  -v | --video-duration <seconds> Set the duration for video segments (default: 60)"
    echo "  -s | --hls-duration <seconds>   Set the duration for HLS segments (default: 10)"
    echo "  -V | --version                  Display version information"
    echo "  -h | --help                     Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -i filename.mkv"
    echo "  $0 -i filename.mkv -l"
    echo "  $0 -i filename.mkv -l -g"
    echo "  $0 -i filename.mkv -g"
}

function parse_arguments() {
    while [[ "$1" != "" ]]; do
        case $1 in
            -d | --work-dir)        shift
                        work_dir="$1"
                                    ;;
            -i | --input )          shift
                        parse_filename "$1"
                                    ;;
            -b | --ffmpeg-bin-dir ) shift
                        parse_ffmpeg_binary "$1"
                                    ;;
            -l | --local-only )
                        localonly="true"
                                    ;;
            -g | --with-gpu )       
                        withgpu="true"
                                    ;;
            -r | --resolutions )    shift
                        parse_resolutions "$1"
                                    ;;
            -a | --audio-duration ) shift
                        audio_segments_duration=$1
                                    ;;
            -v | --video-duration ) shift
                        video_segments_duration=$1
                                    ;;
            -s | --hls_duration )   shift
                        hls_duration=$1
                                    ;;
            -V | --version )       echo "gpff version $VERSION"
                                  exit
                                  ;;
            -h | --help )           usage
                                    exit
                                    ;;
            * )                     usage
                                    exit 1
        esac
        echo $1;
        shift
    done
}

function check_gpu_capability() {
    if [[ "$withgpu" == "true" ]]; then
        checking "for CUDA support in FFmpeg"
        if ! $ffmpeg_binary -hide_banner -filters | grep -q "scale_cuda"; then
            fatal "FFmpeg binary doesn't support CUDA filters"
        fi
        log "ok"
        
        checking "for NVIDIA GPU access"
        if ! command -v nvidia-smi &> /dev/null; then
            fatal "nvidia-smi not found. Please install NVIDIA drivers"
        fi
        if ! nvidia-smi &> /dev/null; then
            fatal "Cannot access NVIDIA GPU. Check driver installation"
        fi
        log "ok"

        # Check GPU on worker nodes if needed
        if [[ "$withgpu" == "true" && "$localonly" != "true" ]]; then
            checking "for GPU capability on worker nodes"
            if ! parallel -S '..' --nonall \
                "$ffmpeg_binary -hide_banner -filters | grep -q scale_cuda && \
                command -v nvidia-smi > /dev/null && nvidia-smi > /dev/null" 2>/dev/null; then
                fatal "One or more worker nodes lack GPU capability"
            fi
            log "ok"
        fi
    fi
}

function check_parallel_citation() {
    if [[ ! -f "$HOME/.parallel/will-cite" ]]; then
        echo "GNU Parallel citation notice:"
        echo "When using programs that use GNU Parallel to process data for publication, please cite:"
        echo ""
        echo "O. Tange (2011): GNU Parallel - The Command-Line Power Tool,"
        echo "The USENIX Magazine, February 2011:42-47."
        echo ""
        echo "This helps funding further development. Type 'will cite' to confirm:"
        read -r response
        if [[ "${response,,}" == "will cite" ]]; then
            mkdir -p "$HOME/.parallel"
            touch "$HOME/.parallel/will-cite"
        else
            fatal "You need to acknowledge GNU Parallel citation notice"
        fi
    fi
}

function check_node_connectivity() {
    if [[ "$localonly" != "true" ]]; then
        checking "for worker nodes configuration"
        if [[ ! -f "$HOME/.parallel/sshloginfile" ]]; then
            fatal "Missing ~/.parallel/sshloginfile. Please configure worker nodes"
        fi
        log "ok"

        checking "connectivity and work directory on worker nodes"
        # Try basic connectivity and work_dir check
        if ! parallel --nonall -S '..' --delay 0.1 --timeout 5 \
            "hostname && test -d $work_dir" 2>/dev/null; then
            fatal "Cannot connect to one or more worker nodes or work_dir missing"
        fi
        log "ok"
        
        checking "ffmpeg on worker nodes"
        if ! parallel --nonall -S '..' --delay 0.1 \
            "test -x $(command -v $ffmpeg_binary) && \
             $ffmpeg_binary -version >/dev/null" 2>/dev/null; then
            fatal "FFmpeg not found or not executable on one or more worker nodes"
        fi
        log "ok"
    fi
}

function init() {
    require "parallel" "run: sudo apt install parallel (or equivalent)"
    
    # Handle GNU Parallel citation
    check_parallel_citation
    
    # Parse all command line arguments
    parse_arguments "$@"
    
    # Validate required arguments
    if [[ -z "$input_file" ]]; then
        fatal "No input file specified"
    fi
    
    # Validate FFmpeg installation
    if [[ -n "$ffmpeg_binary" ]]; then
        require "$ffmpeg_binary" "follow setup instructions for ffmpeg"
        require "$ffprobe_binary" "follow setup instructions for ffmpeg" 
    fi

    # Check worker nodes if running distributed
    check_node_connectivity

    # Check GPU capability if requested
    check_gpu_capability
}

# to make sure that the directory is empty so we won't get any interrupts in the process.
function makedir_or_cleanup() {
    echo -e "${cyanbg}makedir_or_cleanup${clear}"
    mkdir -p "$input_filename"
    rm -rf "$input_filename"/*
    # printing the exit result of the last command. for debug and maybe future use.
    echo -e "${cyanbg}makedir_or_cleanup: $?${clear}"
}

# here we are going to extract each possible audio track from the input file
# first of all, we get the exact stream index of audio streams using ffprobe
# then we create an on-the-fly list of commands based on the index of track[s]
# at the same time, we insert the considered names into a text file to have a list of them
# at the end, we run the generated commands with the main ffmpeg command.
# with that, we open the input file only once with ffmpeg!
# the -map_chapters -1 is important to ignore the data stream in some files
# with chapters
# the sed 's/,//g' is useless in some cases, but it's good to have it. (in some cases you
# will see at least one colon after the number.)
function extract_audios() {
    echo -e "${cyanbg}extract_audios${clear}"
    local audio_indexes=$($ffprobe_binary -loglevel error -select_streams a -show_entries stream=index -of csv=p=0 "$input_file" | sed 's/,//g')
    local lambda_commands=""
    for index in $audio_indexes; do
        local audio_temp_name="audio_stream_$index.m4a"
        # here we are going to use -map 0:index instead of -map a:index
        # that's because we are getting the total index number not index in audio streams
        lambda_commands+=" -map 0:"$index" -copyts -map_chapters -1 -c copy $input_filename/$audio_temp_name "
        echo "$audio_temp_name" >> "$input_filename/audio_list.txt"
    done
    $ffmpeg_binary -i "$input_file" $lambda_commands
    echo -e "${cyanbg}extract_audios: $?${clear}"
}

# here we are going to split the audio files. I prefer not to, but with that, we can
# use the HPC more efficiently and avoid having audio[s] as our bottleneck
function divide_audio() {
    echo -e "${cyanbg}divide_audio${clear}"
    parallel --bar  -j 1 \
        $ffmpeg_binary -i $input_filename/{} -map a -map_chapters -1 -c:a copy -vn -sn \
            -copyts -f segment -segment_time $audio_segments_duration \
             -reset_timestamps 1 \
            -segment_list_type ffconcat -segment_list $input_filename/{.}_segment_list.ffconcat \
            $input_filename/{.}_segment_%04d.m4a \
        :::: $input_filename/audio_list.txt
    echo -e "${cyanbg}divide_audio: $?${clear}"
}

# here we are going to create a simple list of segments based on the number of audios we
# have. we will use this file to transcode remotely.
function create_audio_filelist() {
    echo -e "${cyanbg}create_audio_filelist${clear}"
    for audio_file_name in $(cat "$input_filename/audio_list.txt"); do
        audio_clean_file_name="${audio_file_name%.*}"
        grep -oE '[^ ]+.m4a' "$input_filename/$audio_clean_file_name"_segment_list.ffconcat \
        > $input_filename/"$audio_clean_file_name"_segment_list.txt
    done
    echo -e "${cyanbg}create_audio_filelist: $?${clear}"
}

# here we are going to transcode the audio tracks in parallel remotely if
# there is more than one of them. we decide that at the end of this script.
# about what the parallel command is doing we talk a lot in process_video_transcode_hpc_parallel()
# other than that, there is nothing new to explain
function process_audio_transcode_hpc_parallel() {
    echo -e "${cyanbg}process_audio_transcode_hpc_parallel${clear}"
    # for multi-node run
    cat "$input_filename"/audio_stream_*_segment_list.txt | \
    parallel --bar  -j 2 \
        -S '..,1/:' --delay 0.1 --sshdelay 0.1 --workdir /mnt/data/ \
        --transferfile $input_filename/{}\
        --return $input_filename/transcoded_{} \
        --cleanup \
        $ffmpeg_binary -i $input_filename/{} -copyts \
        -map a -map_chapters -1 -acodec aac -strict experimental -ar 44100 -ac 2 -ab 128k \
        $input_filename/transcoded_{} \
        :::: -
    echo -e "${cyanbg}process_audio_transcode_hpc_parallel: $?${clear}"
}

# here we transcode the audio files locally if there is only one audio track
# or we are running in localonly mode.
# (I think, we should stop using -async 1 here.)
function transcode_audio() {
    echo -e "${cyanbg}transcode_audio${clear}"
    cat "$input_filename"/audio_stream_*_segment_list.txt | \
    parallel --bar  -j 2 \
        $ffmpeg_binary -i $input_filename/{} -copyts \
        -map a -map_chapters -1 -acodec aac -strict experimental -ar 44100 -ac 2 -ab 128k \
        $input_filename/transcoded_{} \
        :::: -
    echo -e "${cyanbg}transcode_audio: $?${clear}"
}

# after transcoding, we need a list of audio files that are transcoded. because the list
# can be dynamic but in static structure, we guess the transcoded file name based on
# the audio list we created in extract_audios(). here we just add transcoded_ to each
# file name in the list.
function create_audio_transcoded_list() {
    echo -e "${cyanbg}create_audio_transcoded_list${clear}"
    for audio_file_name in $(cat "$input_filename/audio_list.txt"); do
        audio_clean_file_name="${audio_file_name%.*}"
        sed 's/\(file \)\(.*\).m4a/\1transcoded_\2\.m4a/g' \
        "$input_filename/$audio_clean_file_name"_segment_list.ffconcat \
        > "$input_filename/transcoded_$audio_clean_file_name"_segment_list.ffconcat
    done
    echo -e "${cyanbg}create_audio_transcoded_list: $?${clear}"
}

# here we are going to assemble the transcoded audio segments. for each audio we have
function assemble_audio_segments() {
    echo -e "${cyanbg}assemble_audio_segments${clear}"
    parallel --bar -j 1 -k \
    $ffmpeg_binary -copyts -f concat -safe 0 -i $input_filename/transcoded_{.}_segment_list.ffconcat \
    -c copy -map 0 $input_filename/transcoded_{} \
    :::: $input_filename/audio_list.txt
    echo -e "${cyanbg}assemble_audio_segments: $?${clear}"
}


# The -flags +global_header flag is used to add global headers to each segment.
# This can be useful in some cases, but it might also increase the processing time.
# IIRC, it will also make the process a bit long because adding global headers to each segment 
# increases the processing time. This is especially true for large files or when the number of segments is high.
# it will add the headers of the main file to each segment file.
# IIRC, it will also make the process a bit long.
    # -flags +global_header \

# here we will separate the file into smaller sections but we will search for keyframes at the end of
# each duration and split at that point.
# it seems that transcoding to .ts is more efficient than to .mkv or .mp4 (forgive me for my lack of knowledge)
# we will save the list of segments in a .concat file so that we will use it after transcoding.
function divide_video() {
    echo -e "${cyanbg}divide_video${clear}"
    # here we are going to calculate the frame_rate to be used in segment_time_delta as explained here in worse case:
    # https://ffmpeg.org/ffmpeg-all.html "For constant frame rate videos a value of 1/(2*frame_rate) should address
    # the worst case mismatch between the specified time and the time set by force_key_frames."
    # but in the several test I had, this calculation until ~10.0 had a same outcome.
    # we can keep it or ignore it
    local frame_rate=$($ffprobe_binary -v 0 -of csv=p=0 -select_streams v:0 -show_entries stream=r_frame_rate $input_file)
    # (we don't use the bc here because of its incompablity)
    local segment_time_delta=$(awk 'BEGIN{printf "%6f", 1/(2*'$frame_rate')}')
    # here we just do some split-copy but I think -copyts is also useful in some cases and it can't hurt
    # so do avoid_negative_ts
    # this is important to note that WE DO NOT COPY/transfer ANY SUBTITLES!!! because I have had problem in some
    # cases. if you want the subtitle, you can extract it easily and attach it again. so with -sn, we ignore/delete
    # the subtitles in transcoding process!
    # copilot said: The -map v option in the ffmpeg command may cause issues if the input file contains 
    # multiple video streams. Specify the exact stream index to avoid ambiguity.
    # and suggested to use -map 0:v:0 instead of -map v
    $ffmpeg_binary -i $input_file -map v -map_chapters -1 -c copy -an -sn \
        -copyts -force_key_frames "expr:gte(t,n_forced*$video_segments_duration)" \
        -f segment -segment_time_delta $segment_time_delta -segment_time $video_segments_duration \
         -reset_timestamps 1 \
        -segment_list_type ffconcat -segment_list $input_filename/video_segment_list.ffconcat \
        $input_filename/video_segment_%04d.ts
    echo -e "${cyanbg}divide_video: $?${clear}"
}

# here we just create a simple list of files using the .ffconcat file which has a special data format.
function create_video_filelist() {
    echo -e "${cyanbg}create_video_filelist${clear}"
    grep -oE '[^ ]+.ts' "$input_filename/video_segment_list.ffconcat" > "$input_filename/video_segment_list.txt"
    echo -e "${cyanbg}create_video_filelist: $?${clear}"
}

# here we will create a directory on the nodes/worker servers similar to makedir_or_cleanup()
# before starting the main transcode process in process_video_transcode_hpc_parallel()
# for more details about the commands, see the comments before process_video_transcode_hpc_parallel()
function remote_mkdir_filename() {
    echo -e "${cyanbg}remote_mkdir_filename${clear}"
    parallel -j1 --onall \
        -S '..' --sshdelay 0.1 --workdir /mnt/data/ \
        mkdir -p {}\; rm -f {}/* ::: "$input_filename"
    echo -e "${cyanbg}remote_mkdir_filename: $?${clear}"
}

# here we will remove the directory we created in makedir_or_cleanup() after the main transcode
# process in process_video_transcode_hpc_parallel()
# for more details about the commands, see the comments before process_video_transcode_hpc_parallel()
function remote_rm_filename() {
    echo -e "${cyanbg}remote_rm_filename${clear}"
    parallel -j1 --onall\
        -S '..' --sshdelay 0.1 --workdir /mnt/data/ \
        rm -rf {}/::: "$input_filename"
    echo -e "${cyanbg}remote_rm_filename: $?${clear}"
}

# we do some magic here using parallel, soon we will go for slurm for better monitoring, but here it is.
# you can see most of it by reading the man page of parallel, but -j+0 means to run parallel as much as
# our CPU cores. you can see the number using: parallel --number-of-cores
# using -S '..,1/:' means that we are using ~/.parallel/sshloginfile as our remote node list (i.e '..', the workers)
# and using one core (i.e '1/') of our local server (i.e ':', the master/the server we run the `parallel` command)
# we use 100 milliseconds delay for processing new input and 100 milliseconds for SSH parallel commands so that it
# will be less aggressive in using disk and network alike.
# with --work-dir we specify where files should be transferred and processed (see the next paragraph). but
# note that if you specified the local server for processing, the current files also should be in the --work-dir
# otherwise, the parallel can't find the input file to begin with. (be careful with the drawback)
# then we say to transfer the input and then return the files starting with 'transcode_' and the name of the input.
# after that, clean the transferred file (i.e the input) and the returned files, also if there was/were a/any
# --base-file['s'] used.
# you can do anything else here in ffmpeg, we don't care, but DON'T FORGET to handle the --return correctly.
# finally, we give the input list to the parallel, to choose the files as it likes. it will give each input
# in the list to each server as much as it can based on -j arguments and server load. but keep in mind that
# do not use -j0 (not -j+0) because in some cases, it will slow you down rather than be beneficial. also, I personally
# prefer not to use the local server (i.e master) for transcoding. because mostly it will drain the RAM and
# slow us down, because ffmpeg is using multi-thread itself even if we force parallel to use one CPU core. but
# the question here is why we are using -j+0 to use all cores if ffmpeg is doing it itself? the answer
# is that ffmpeg has its own bottlenecks and in some cases, I find it beneficial this way. (maybe I'm wrong?)
# in the new tests, I decided to use -fps_mode passthrough not anything else. so we will have a
# synchronized output at the end. in my several tests, the audio timing was just fine, but the
# only problem was the video. now that even transcoding mp4 has no problem.
function process_video_transcode_hpc_parallel() {
    echo -e "${cyanbg}process_video_transcode_hpc_parallel${clear}"
    # for multi-node run
    local lambda_video_return=""
    local lambda_video=""
    for resolution in ${resolutions[@]}; do
        lambda_video+=" -pix_fmt yuv420p -fps_mode passthrough -vcodec h264 \
        -vf scale=-2:$resolution $input_filename/transcoded_${resolution}p_{} "
        lambda_video_return+=" --return $input_filename/transcoded_${resolution}p_{} "
    done
    parallel --bar  -j 2 \
        -S '..,1/:' --delay 0.1 --sshdelay 0.1 --workdir /mnt/data/ \
        --transferfile $input_filename/{}\
        $lambda_video_return \
        --cleanup \
        $ffmpeg_binary -i $input_filename/{} -copyts \
        $lambda_video \
        :::: $input_filename/video_segment_list.txt
    echo -e "${cyanbg}process_video_transcode_hpc_parallel: $?${clear}"
}

# same as above but with GPU!
# NOTE: we only use one of the process_video_transcode_*_parallel() functions.
function process_video_transcode_hpc_gpu_parallel() {
    echo -e "${cyanbg}process_video_transcode_hpc_gpu_parallel${clear}"
    # for multi-node run
    local lambda_video_return=""
    local lambda_video=""
    for resolution in ${resolutions[@]}; do
        lambda_video+=" -fps_mode passthrough -vf scale_cuda=w=-1:h=$resolution \
        -vcodec h264_nvenc $input_filename/transcoded_${resolution}p_{} "
        lambda_video_return+=" --return $input_filename/transcoded_${resolution}p_{} "
    done
    parallel --bar  -j 2 \
        -S '..,1/:' --delay 0.1 --sshdelay 0.1 --workdir /mnt/data/ \
        --transferfile $input_filename/{}\
        $lambda_video_return \
        --cleanup \
        $ffmpeg_binary -vsync 0 -hwaccel cuda -hwaccel_output_format cuda \
        -i $input_filename/{} -copyts $lambda_video \
        :::: $input_filename/video_segment_list.txt
    echo -e "${cyanbg}process_video_transcode_hpc_gpu_parallel: $?${clear}"
}

# same as above but only on the local machine with CPU!
# NOTE: we only use one of the process_video_transcode_*_parallel() functions.
function process_video_transcode_localonly_parallel() {
    echo -e "${cyanbg}process_video_transcode_localonly_parallel${clear}"
    # for local run,
    local lambda_video=""
    for resolution in ${resolutions[@]}; do
        lambda_video+=" -pix_fmt yuv420p -fps_mode passthrough -vcodec h264 \
        -vf scale=-2:$resolution $input_filename/transcoded_${resolution}p_{} "
    done
    parallel --bar  -j 2 \
        $ffmpeg_binary -i $input_filename/{} -copyts \
        $lambda_video \
        :::: $input_filename/video_segment_list.txt
    echo -e "${cyanbg}process_video_transcode_localonly_parallel: $?${clear}"
}

# same as above but only on the local machine with GPU!
# NOTE: we only use one of the process_video_transcode_*_parallel() functions.
function process_video_transcode_localonly_gpu_parallel() {
    echo -e "${cyanbg}process_video_transcode_localonly_gpu_parallel${clear}"
    # for local run,
    local lambda_video=""
    for resolution in ${resolutions[@]}; do
        lambda_video+=" -fps_mode passthrough -vf scale_cuda=w=-1:h=$resolution \
        -vcodec h264_nvenc $input_filename/transcoded_${resolution}p_{} "
    done
    parallel --bar  -j 2 \
        $ffmpeg_binary -vsync 0 -hwaccel cuda -hwaccel_output_format cuda \
        -i $input_filename/{} -copyts $lambda_video \
        :::: $input_filename/video_segment_list.txt
    echo -e "${cyanbg}process_video_transcode_localonly_gpu_parallel: $?${clear}"
}

# here we create a .ffconcat file for each resolution using the first .ffconcat file.
function create_resolutions_segment_list() {
    echo -e "${cyanbg}create_resolutions_segment_list${clear}"
    for resolution in ${resolutions[@]}; do
        sed "s/\(file \)\(.*\).ts/\1transcoded_${resolution}p_\2\.ts/g" \
        $input_filename/video_segment_list.ffconcat > $input_filename/video_segment_list_${resolution}p.ffconcat
    done
    echo -e "${cyanbg}create_resolutions_segment_list: $?${clear}"
}

# finally we assemble/concat the segments of each resolution based on each resolution .ffconcat file.
# it happens very fast so that we can even ignore using the parallel command and use a `for` loop.
function assemble_video_segments() {
    echo -e "${cyanbg}assemble_video_segments${clear}"
    parallel --bar -j 1 -k \
    $ffmpeg_binary -copyts -f concat -safe 0 -i $input_filename/video_segment_list_{1}p.ffconcat \
    -c copy -map 0 $input_filename/transcoded_video_$input_filename.{1}p$input_extension \
    ::: ${resolutions[@]}
    echo -e "${cyanbg}assemble_video_segments: $?${clear}"
}

# here we join the audios and videos in a new file.
# same as extract_audios() we create a list of commands on the fly, the name of files as
# input and then map them with their sequential index number in the first input file.
# the -map starts with 0 but we have the video as input in that position. so audio starts
# at 1.
function join_audios_videos() {
    echo -e "${cyanbg}join_audios_videos${clear}"
    local lambda_audio=""
    local lambda_audio_map=""
    local counter=1
    for audio_filename in $(cat "$input_filename/audio_list.txt"); do
        lambda_audio+=" -i $input_filename/transcoded_$audio_filename "
        lambda_audio_map+=" -map $counter:a "
        ((counter++))
    done
    parallel --bar -j 1 -k \
    $ffmpeg_binary -copyts \
    -i "$input_filename/transcoded_video_$input_filename.{1}p$input_extension"  \
    $lambda_audio \
    -c copy -map 0 \
    $lambda_audio_map \
    "$input_filename/$input_filename.{1}p$input_extension" \
    ::: ${resolutions[@]}
    echo -e "${cyanbg}join_audios_videos: $?${clear}"
}


# here we are going to clean the segments to free up the space. because we used them
# in assembling sections.
function segments_cleanup() {
    echo -e "${cyanbg}segments_cleanup${clear}"
    rm -f "$input_filename"/*segment_*
    echo -e "${cyanbg}segments_cleanup: $?${clear}"
}

# This is a test function to measure the time taken for splitting in HLS mode for all video 
# and audio files. The master playlist is not useful if you want to use it in VLC.
# Therefore, I removed the last part of the master playlist to fix it.
# I haven't added language and correct naming for them yet, as it requires extensive testing
# with various files, which I haven't had time for.
function make_hls() {
    echo -e "${cyanbg}make_hls${clear}"
    local counter=0
    local var_stream_map=""
    local video_counter=0
    local lambda_video=""
    local lambda_video_map=""
    local lambda_video_copy=""
    for resolution in ${resolutions[@]}; do
        lambda_video+=" -i $input_filename/transcoded_video_$input_filename.${resolution}p$input_extension "
        lambda_video_map+=" -map $counter:v:0 "
        lambda_video_copy+=" -c:v:$video_counter copy -copyts "
        var_stream_map+="v:$video_counter,agroup:vidaud,name:video_$video_counter "
        ((video_counter++))
        ((counter++))
    done
    local audio_counter=0
    local lambda_audio=""
    local lambda_audio_map=""
    local lambda_audio_copy=""
    for audio_filename in $(cat "$input_filename/audio_list.txt"); do
        lambda_audio+=" -i $input_filename/transcoded_$audio_filename "
        lambda_audio_map+=" -map $counter:a:0 "
        lambda_audio_copy+=" -c:a:$audio_counter copy -copyts "
        var_stream_map+="a:$audio_counter,agroup:vidaud,name:audio_$audio_counter "
        ((audio_counter++))
        ((counter++))
    done
    mkdir -p "$input_filename/hls"
    $ffmpeg_binary \
        $lambda_video \
        $lambda_audio \
        $lambda_video_map \
        $lambda_audio_map \
        $lambda_video_copy \
        $lambda_audio_copy \
       -var_stream_map "$var_stream_map" \
       -force_key_frames "expr:gte(t,n_forced*$hls_duration)" \
       -f hls -hls_time $hls_duration -hls_flags independent_segments \
       -hls_segment_type mpegts \
       -hls_playlist true -hls_playlist_type vod -master_pl_name playlist.m3u8 \
       -hls_segment_filename "$input_filename/hls/%v/file_%04d.ts" \
       "$input_filename/hls/%v/index.m3u8"
    # removing audio stream part in the master playlist
    sed -i '/CODECS="mp4a.40.2"/,+1d' "$input_filename/hls/playlist.m3u8"
    echo -e "${cyanbg}make_hls: $?${clear}"
}

# here we clean up the temporary files locally and only the final transcoded files will remain.
function final_cleanup() {
    echo -e "${cyanbg}final_cleanup${clear}"
    rm -f "$input_filename"/transcoded_*
    rm -f "$input_filename"/audio_stream_*
    rm -f "$input_filename/audio_list.txt"
    echo -e "${cyanbg}final_cleanup: $?${clear}"
}


# Main execution starts here

# here we run the command step by step and wait in each step to be truly completed before going to the next one
# time is for debug only. we usually don't need the &wait at all. but in some cases, it will be helpful

init "$@"

sleep 1

time makedir_or_cleanup &
wait

time extract_audios &
wait

time divide_audio &
wait

time create_audio_filelist &
wait

time divide_video &
wait

time create_video_filelist &
wait

# if this script is used like : bash gpff.bash "filename.mkv" true
# it will only run in localonly mode
if [[ $localonly != "true" ]]; then
    time remote_mkdir_filename &
    wait
    time process_audio_transcode_hpc_parallel &
    wait
    # if this script is used like : bash gpff.bash "filename.mkv" false true
    # it will transcode with GPU on all servers
    if [[ $withgpu != "true" ]]; then
        time process_video_transcode_hpc_parallel &
        wait
    else
        time process_video_transcode_hpc_gpu_parallel &
        wait
    fi
    time remote_rm_filename &
    wait
else
    time transcode_audio &
    wait
    # if this script is used like : bash gpff.bash "filename.mkv" true true
    # it will transcode with local GPU
    if [[ $withgpu != "true" ]]; then
        time process_video_transcode_localonly_parallel &
        wait
    else
        time process_video_transcode_localonly_gpu_parallel &
        wait
    fi
fi


time create_audio_transcoded_list &
wait

time assemble_audio_segments &
wait

time create_resolutions_segment_list &
wait
time assemble_video_segments &
wait

time join_audios_videos &
wait

time segments_cleanup &
wait

time make_hls &
wait

time final_cleanup &
wait

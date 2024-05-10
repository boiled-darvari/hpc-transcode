#!/bin/bash

#
#
# how to use:
#
# $ bash gpff.bash "filename.mkv"
#
# or just to run locally:
# bash gpff.bash "filename.mkv" true
#
# (it's better if you run inside tmux)
#

# our color for just separate the sections.
cyanbg="\033[0;46m"
clear="\033[0m"

work_dir="/mnt/data/"

# analysing the input
input_file="$1"
input_extension=".${input_file##*.}"
input_filename="${input_file%.*}"

# do we want to transcode only mkv files?
# if [[ input_extension != ".mkv" ]] ; then
#     echo "give me .mkv"
#     exit 1
# fi

# to check if we should run local only. we will use it at the end.
localonly="$2"

# to make sure that the directory is empty so we won't get any intrupts in the process.
function makedir_or_cleanup() {
    echo -e "${cyanbg}makedir_or_cleanup${clear}"
    mkdir -p $input_filename
    rm -f $input_filename/*
    # printing the exit result of the last command. for debug and maybe future use.
    echo -e "${cyanbg}makedir_or_cleanup: $?${clear}"
}

# I'm not sure about this flag yet, let's keep it here.
# it will add the headers of the main file to each segment files.
# IIRC, it will also make the process a bit long.
    # -flags +global_header \

# here we will separate the file into smaller section but we will search for keyframes at the end of
# each duration and split at that point.
# it seems that transcoding to .ts is more efficent than to .mkv or .mp4 (forgive me for my lack of knowledge)
# we will save the list of segments in a .concat file so that we will use it after transcoding.
function divide_mkv() {
    echo -e "${cyanbg}divide_mkv${clear}"
    # the duration can be anything, but the smaller it goes, the more overhead we will have.
    # also the bigger it goes, there is a chance that we will have the last file our bottleneck.
    # so it should be not so long, not so short. 200 in seconds means 00:03:20
    # UPDATE:
    # one of the interesting examples is this blow file (magnet link):
    # ```
    # transmission-cli "magnet:?xt=urn:btih:F6468653281CC3CD9BDA3E78F399752C13CBA61D&dn=Madame.Web.2024.1080p.10bit.WEBRip.6CH.x265.HEVC-PSA&tr=udp%3A%2F%2Fbt1.archive.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=https%3A%2F%2Ftracker1.520.jp%3A443%2Fannounce&tr=udp%3A%2F%2Fopentracker.i2p.rocks%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.demonii.com%3A1337%2Fannounce&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A6969%2Fannounce&tr=http%3A%2F%2Ftracker.openbittorrent.com%3A80%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Fexodus.desync.com%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce&tr=http%3A%2F%2Fbt.endpot.com%3A80%2Fannounce&tr=udp%3A%2F%2Fuploads.gamecoast.net%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker1.bt.moack.co.kr%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=http%3A%2F%2Ftracker.openbittorrent.com%3A80%2Fannounce&tr=udp%3A%2F%2Fopentracker.i2p.rocks%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.internetwarriors.net%3A1337%2Fannounce&tr=udp%3A%2F%2Ftracker.leechers-paradise.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fcoppersurfer.tk%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.zer0day.to%3A1337%2Fannounce"
    # ```
    #
    # in above file, with 200 seconds, I had several errors but more important one was this one for the
    # last segment:
    # ```
    # [mpegts @ 0x558674a05380] start time for stream 1 is not set in estimate_timings_from_pts
    # [mpegts @ 0x558674a05380] stream 1 : no TS found at start of file, duration not set
    # [mpegts @ 0x558674a05380] Could not find codec parameters for stream 1 (Audio: aac ([15][0][0][0] / 0x000F), 0 channels): unspecified sample format
    # Consider increasing the value for the 'analyzeduration' (0) and 'probesize' (5000000) options
    # ```
    #
    # the main error is this: "Could not find codec parameters for stream 1 (Audio: aac"
    # let's look at it deeper.
    # ```
    # $ probe -i "Madame*.mkv"
    #  Stream #0:0: Video: [SNIP]
    #     Metadata:
    #       BPS             : 1722575
    #       DURATION        : 01:57:49.938000000
    #       [SNIP]
    #   Stream #0:1(eng): Audio: aac (HE-AAC), 48000 Hz, 5.1, fltp (default)
    #     Metadata:
    #       BPS             : 207064
    #       DURATION        : 01:56:11.222000000
    # ```
    #
    # you can see that there is a different between duration of video and audio. so lest see what's happened
    # to the last segment we had:
    # ```
    # $ ffprobe -i "Madame*/segment_0035.ts"
    #   Duration: 00:01:06.27, start: 1.567000, bitrate: 105 kb/s
    #   [SNIP]
    #   Stream #0:0[0x100]: Video: hevc (Main 10) (HEVC / 0x43564548), yuv420p10le(tv, bt709), 1920x800, 23.98 fps, 23.98 tbr, 90k tbn
    #   Stream #0:1[0x101](eng): Audio: aac ([15][0][0][0] / 0x000F), 0 channels
    # ```
    #
    local duration=300
    # here we are going to calculate the frame_rate to be used in segment_time_delta as explained here in worse case:
    # https://ffmpeg.org/ffmpeg-all.html "For constant frame rate videos a value of 1/(2*frame_rate) should address
    # the worst case mismatch between the specified time and the time set by force_key_frames."
    # but in the several test I had, this calculation until ~10.0 had a same outcome.
    # we can keep it or ignore it
    local frame_rate=$(ffprobe -v 0 -of csv=p=0 -select_streams v:0 -show_entries stream=r_frame_rate $input_file)
    local segment_time_delta=$(awk 'BEGIN{printf "%6f", 1/(2*'$frame_rate')}')
    # here we just do some split-copy but I think -copyts is also useful in some cases and it can't hurt
    # so do avoid_negative_ts
    # this is important to note that WE DO NOT COPY/transfer ANY SUBTITLES!!! because I have had problem in some
    # cases. if you want the subtitle, you can extract it easily and attach it again. so with -sn, we ignore/delete
    # the subtitles in transcoding process!
    ffmpeg -i $input_file -c copy -sn -copyts -force_key_frames "expr:gte(t,n_forced*$duration)" -f segment \
        -segment_time_delta $segment_time_delta -segment_time $duration \
        -avoid_negative_ts 1  -reset_timestamps 1 -map 0 \
        -segment_list_type ffconcat -segment_list $input_filename/segment_list.ffconcat \
        $input_filename/segment_%04d.ts
    echo -e "${cyanbg}divide_mkv: $?${clear}"
}

# here we just create a simple list of files using the .ffconcat file which has a special data format.
function create_filelist() {
    echo -e "${cyanbg}create_filelist${clear}"
    grep -oE '[^ ]+.ts' $input_filename/segment_list.ffconcat > $input_filename/segment_list.txt
    echo -e "${cyanbg}create_filelist: $?${clear}"
}

# here we will create a directory in the nodes/worker servers similar to makedir_or_cleanup()
# before starting the main transcode process in process_transcode_hpc_parallel()
# for more details about the commands, see the comments before process_transcode_hpc_parallel()
function remote_mkdir_filename() {
    echo -e "${cyanbg}remote_mkdir_filename${clear}"
    parallel -j1 --onall \
        -S '..' --sshdelay 0.1 --workdir /mnt/data/ \
        mkdir -p {}\; rm -f {}/* ::: $input_filename
    echo -e "${cyanbg}remote_mkdir_filename: $?${clear}"
}

# here we will remove the directory we created in makedir_or_cleanup() after the main transcode
# process in process_transcode_hpc_parallel()
# for more details about the commands, see the comments before process_transcode_hpc_parallel()
function remote_rm_filename() {
    echo -e "${cyanbg}remote_rm_filename${clear}"
    parallel -j1 --onall\
        -S '..' --sshdelay 0.1 --workdir /mnt/data/ \
        rm -rf {}/::: $input_filename
    echo -e "${cyanbg}remote_rm_filename: $?${clear}"
}

# we do some magic here using parallel, soon we will go for slurm for a better monitoring, but here it is.
# you can can see most of it by reading the man page of parallel, but -j+0 means to run parallel as much as
# our CPU cores. you can see the number using: parallel --number-of-cores
# using -S '..,1/:' means that we are using ~/.parallel/sshloginfile as our remote node list (i.e '..', the workers)
# and using one core (i.e '1/') of our local server (i.e ':', the master/the server we run the `parallel` command)
# we use 100 miliseonds delay for processing new input and 100 miliseonds for SSH parallel commands so that it
# will be less agressive in using disk and network alike.
# with --work-dir we specifying where should files be transfered and processed (see the next paragraph). but
# note that if you specified the local server for processing, the current files also should be in the --work-dir
# otherwise, the parallel can't find the input file to begin with. (be careful with the drawback)
# then we say to transfer the input and then return the files started with 'transcode_' and the name of the input.
# after that, clean the transfered file (i.e the input) and the returned files, also if there was/were a/any
# --base-file['s'] used.
# you can do anything else here in ffmpeg, we don't care, but DON'T FORGET to handle the --return correctly.
# finally, we gave the input list to the parallel, to choose the files as it likes. it will give each input
# in the list to each server as much as it can based on -j arguments and server load. but keep it in mind that
# do not use -j0 (not -j+0) because in some cases, it will slow you down than to be beneficent. also, I presonally
# prefer to to not use local server (i.e master) for transcoding. because mostly it will drain the RAM and
# slow us down, because the ffmpeg is using multi-thread itself even we force parallel to use one CPU core. but
# the qustion here is that why we are using -j+0 to use all cores, if the ffmpeg is doing it itself? the answer
# is that the ffmpeg has it's own bottlenecks and in some cases, I find it beneficial this way. (maybe I'm wrong?)
function process_transcode_hpc_parallel() {
    echo -e "${cyanbg}process_transcode_hpc_parallel${clear}"
    # for multi-node run
    parallel --bar  -j 1 \
        -S '..,:' --delay 0.1 --sshdelay 0.1 --workdir /mnt/data/ \
        --transferfile $input_filename/{}\
        --return $input_filename/transcoded_720p_{} \
        --return $input_filename/transcoded_480p_{} \
        --return $input_filename/transcoded_360p_{} \
        --cleanup \
        ffmpeg -analyzeduration 10000000 -probesize 10000000 -i $input_filename/{} -copyts \
        -map 0 -acodec aac -strict experimental -async 1 -ar 44100 -ac 2 -ab 128k \
        -pix_fmt yuv420p -fps_mode cfr -vcodec h264 \
        -vf scale=1280x720 $input_filename/transcoded_720p_{} \
        -map 0 -acodec aac -strict experimental -async 1 -ar 44100 -ac 2 -ab 128k \
        -pix_fmt yuv420p -fps_mode cfr -vcodec h264 \
        -vf scale=-2:480 $input_filename/transcoded_480p_{} \
        -map 0 -acodec aac -strict experimental -async 1 -ar 44100 -ac 2 -ab 128k \
        -pix_fmt yuv420p -fps_mode cfr -vcodec h264 \
        -vf scale=-2:360 $input_filename/transcoded_360p_{} \
        :::: $input_filename/segment_list.txt
    echo -e "${cyanbg}process_transcode_hpc_parallel: $?${clear}"
}

# same as above but only on local machine! we only use one of the process_transcode_*_parallel() functions.
# if you want to use localonly, change the function call at the end of this script to this name and
# also comment out the the remote_*_filename() calls
function process_transcode_localonly_parallel() {
    echo -e "${cyanbg}process_transcode_localonly_parallel${clear}"
    # for local run,
    parallel --bar  -j+0 \
        ffmpeg -analyzeduration 10000000 -probesize 10000000 -i $input_filename/{} -copyts \
        -map 0 -acodec aac -strict experimental -async 1 -ar 44100 -ac 2 -ab 128k \
        -pix_fmt yuv420p -fps_mode cfr -vcodec h264 \
        -vf scale=1280x720 $input_filename/transcoded_720p_{} \
        -map 0 -acodec aac -strict experimental -async 1 -ar 44100 -ac 2 -ab 128k \
        -pix_fmt yuv420p -fps_mode cfr -vcodec h264 \
        -vf scale=-2:480 $input_filename/transcoded_480p_{} \
        -map 0 -acodec aac -strict experimental -async 1 -ar 44100 -ac 2 -ab 128k \
        -pix_fmt yuv420p -fps_mode cfr -vcodec h264 \
        -vf scale=-2:360 $input_filename/transcoded_360p_{} \
        :::: $input_filename/segment_list.txt
    echo -e "${cyanbg}process_transcode_localonly_parallel: $?${clear}"
}

# Armin's ffmpeg flags:
# -i downloads/053092d3-7845-4428-a40a-4cead148559a -y -threads 2 -map 0:a:0 -acodec aac -strict experimental -async 1 -ar 44100 -ac 2 -ab 128k -f segment -segment_time 10 -segment_list_size 0 -segment_list_flags -cache -segment_format aac -segment_list movies/053092d3-7845-4428-a40a-4cead148559a/audio/0/128k/audio.m3u8 movies/053092d3-7845-4428-a40a-4cead148559a/audio/0/128k/audio%d.aac -map 0:v:0 -pix_fmt yuv420p -vsync 1 -async 1 -vcodec h264 -vf scale=854x480 -f hls -hls_playlist_type vod -hls_time 10 -hls_list_size 0 movies/053092d3-7845-4428-a40a-4cead148559a/video/480p/index.m3u8 -map 0:v:0 -pix_fmt yuv420p -vsync 1 -async 1 -vcodec h264 -vf scale=1280x720 -f hls -hls_playlist_type vod -hls_time 10 -hls_list_size 0 movies/053092d3-7845-4428-a40a-4cead148559a/video/720p/index.m3u8
#

# here we create a .ffconcat file for each resolution using the first .ffconcat file.
function create_resolutions_segment_list() {
    echo -e "${cyanbg}create_resolutions_segment_list${clear}"
    for resolution in 360p 480p 720p; do
        sed 's/\(file \)\(.*\).ts/\1transcoded_'$resolution'_\2\.ts/g' \
        $input_filename/segment_list.ffconcat > $input_filename/segment_list_$resolution.ffconcat
    done
    echo -e "${cyanbg}create_resolutions_segment_list: $?${clear}"
}

# finally we assemble/concat the segments of each resolution based on the each resolution .ffconcat file.
# it happens very fast so that we can even ignore using the parallel command and use a `for` loop.
function assemble_segments() {
    echo -e "${cyanbg}assemble_segments${clear}"
    parallel --bar -j+0 \
    ffmpeg -f concat -safe 0 -i $input_filename/segment_list_{1}.ffconcat \
    -c copy -map 0 -avoid_negative_ts 1 $input_filename/$input_filename.{1}$input_extension \
    ::: 360p 480p 720p
    echo -e "${cyanbg}assemble_segments: $?${clear}"
}

# here we cleanup the temporarily files in local and only the final transcooded files will remain.
function final_cleanup() {
    echo -e "${cyanbg}final_cleanup${clear}"
    rm -f $input_filename/*segment_*
    echo -e "${cyanbg}final_cleanup: $?${clear}"
}

# here we run the command step by step and wait in each step to be truely completed before going to next done
# time is for debug only. we usually don't need the &wait at all. but in some cases will be helpful
time makedir_or_cleanup &
wait
time divide_mkv &
wait

time create_filelist &
wait

# if this script is used like : bash gpff.bash "filename.mkv" true
# it will only in localonly mode
if [[ $localonly != "true" ]]; then
    time remote_mkdir_filename &
    wait
    time process_transcode_hpc_parallel &
    wait
    time remote_rm_filename &
    wait
else
    time process_transcode_localonly_parallel &
    wait
fi

time create_resolutions_segment_list &
wait
time assemble_segments &
wait

# time final_cleanup &
# wait

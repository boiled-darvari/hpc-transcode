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

# analysing the input and change the spaces in the name to dash
# so that we will see less bugs in the future
input_temp_name="$1"
input_corrected_name=$(echo "$input_temp_name" | sed 's/[][ ]/\-/g')
if [[ "$input_temp_name" != "$input_corrected_name" ]]; then
    mv "$input_temp_name" $input_corrected_name
fi

input_file="$input_corrected_name"
input_extension=".${input_file##*.}"
input_filename="${input_file%.*}"

# here we choose between static build of ffmpeg and packages.
ffmpeg_binary="./ffmpeg-git-20240504-amd64-static/ffmpeg"
# ffmpeg_binary="/mnt/data/ffmpeg-git-20240504-amd64-static/ffmpeg"
# ffmpeg_binary="ffmpeg"

# here we choose between static build of ffprobe and packages.
ffprobe_binary="./ffmpeg-git-20240504-amd64-static/ffprobe"
# ffprobe_binary="/mnt/data/ffmpeg-git-20240504-amd64-static/ffprobe"
# ffprobe_binary="ffprobe"

# do we want to transcode only mkv and mp4 files?
if [[ "$input_extension" != ".mkv" ]] || [[ "$input_extension" != ".mp4" ]] ; then
    echo "give me .mkv or .mp4"
    exit 1
fi

# to check if we should run local only. we will use it at the end.
localonly="$2"


resolutions=( "360" "480" "720" )

# the duration can be anything, but the smaller it goes, the more overhead we will have.
# also the bigger it goes, there is a chance that we will have the last file our bottleneck.
# so it should be not so long, not so short. 200 in seconds means 00:03:20
audio_segments_duration=600
video_segments_duration=60

# the duration when we doing HLS. note that in some cases the keyframes I saw was interval 10 seconds!
hls_duration=10


# to make sure that the directory is empty so we won't get any intrupts in the process.
function makedir_or_cleanup() {
    echo -e "${cyanbg}makedir_or_cleanup${clear}"
    mkdir -p $input_filename
    rm -f $input_filename/*
    # printing the exit result of the last command. for debug and maybe future use.
    echo -e "${cyanbg}makedir_or_cleanup: $?${clear}"
}

# here we are going to extract each possible audio tracks from the input file
# first of all, we get the exact stream index of audio streams using ffprobe
# then we create a on the fly list of commands based on the index of track[s]
# at the same time, we insert the considered names to a text file to have a list of them
# at the end, we run the generated commands with the main ffmpeg command.
# with that, we open the input file only once with ffmpeg!
# the -map_chapters -1 is important to ignore the data stream in some files
# with chapters
# the sed 's/,//g' is useles in some cases, but it's good to have it. (in some cases you
# will see at least one colon after the number.)
function extract_audios() {
    echo -e "${cyanbg}extract_audios${clear}"
    local audio_indexes=$($ffprobe_binary -loglevel error -select_streams a -show_entries stream=index -of csv=p=0 $input_file | sed 's/,//g')
    local lambda_commands=""
    for index in $audio_indexes; do
        local audio_temp_name="audio_stream_$index.m4a"
        # here we are going to use -map 0:index instead of -map a:index
        # that's because we are getting the total index number not index in audio streams
        lambda_commands+=" -map 0:"$index" -copyts -map_chapters -1 -c copy $input_filename/$audio_temp_name "
        echo "$audio_temp_name" >> $input_filename/audio_list.txt
    done
    $ffmpeg_binary -i $input_file $lambda_commands
    echo -e "${cyanbg}extract_audios: $?${clear}"
}

# here we are going to split the audio files. I prefer not to, but with that, we can
# use the HPC more efficent and avoid having audio[s] as our work bottleneck
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

# here we are going to create a simple list of segments based on the the number of audios we
# have. we will use this file to transcode remotely.
function create_audio_filelist() {
    echo -e "${cyanbg}create_audio_filelist${clear}"
    for audio_file_name in $(cat $input_filename/audio_list.txt); do
        audio_clean_file_name="${audio_file_name%.*}"
        grep -oE '[^ ]+.m4a' $input_filename/"$audio_clean_file_name"_segment_list.ffconcat \
        > $input_filename/"$audio_clean_file_name"_segment_list.txt
    done
    echo -e "${cyanbg}create_audio_filelist: $?${clear}"
}

# here we are going to transcode the audio tracks in parallel remotely if
# there are more than one of them. we decide that at the end of this script.
# about what the parallel command is doing we talk a lot in process_video_transcode_hpc_parallel()
# other than that, there is nothing new to explain
function process_audio_transcode_hpc_parallel() {
    echo -e "${cyanbg}process_audio_transcode_hpc_parallel${clear}"
    # for multi-node run
    cat $input_filename/audio_stream_*_segment_list.txt | \
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

# here we transcode the audio files locally if the audio tracks are only one
# or we are running in localonly mode.
# (I think, we should stop using -async 1 here.)
function transcode_audio() {
    echo -e "${cyanbg}transcode_audio${clear}"
    cat $input_filename/audio_stream_*_segment_list.txt | \
    parallel --bar  -j 2 \
        $ffmpeg_binary -i $input_filename/{} -copyts \
        -map a -map_chapters -1 -acodec aac -strict experimental -ar 44100 -ac 2 -ab 128k \
        $input_filename/transcoded_{} \
        :::: -
    echo -e "${cyanbg}transcode_audio: $?${clear}"
}

# after transcoding, we need a list of audio files that are transcoded. because the list
# can be dynamic but in static structure, we guess the transcodded file name based on
# the audio list we created in extract_audios(). here we just add transcoded_ to each
# file name in the list.
function create_audio_transcoded_list() {
    echo -e "${cyanbg}create_audio_transcoded_list${clear}"
    for audio_file_name in $(cat $input_filename/audio_list.txt); do
        audio_clean_file_name="${audio_file_name%.*}"
        sed 's/\(file \)\(.*\).m4a/\1transcoded_\2\.m4a/g' \
        $input_filename/"$audio_clean_file_name"_segment_list.ffconcat \
        > $input_filename/transcoded_"$audio_clean_file_name"_segment_list.ffconcat
    done
    echo -e "${cyanbg}create_audio_transcoded_list: $?${clear}"
}

# here we are going to assemble the the transcodded audio segments. for each audio we have
function assemble_audio_segments() {
    echo -e "${cyanbg}assemble_audio_segments${clear}"
    parallel --bar -j 1 -k \
    $ffmpeg_binary -copyts -f concat -safe 0 -i $input_filename/transcoded_{.}_segment_list.ffconcat \
    -c copy -map 0 $input_filename/transcoded_{} \
    :::: $input_filename/audio_list.txt
    echo -e "${cyanbg}assemble_audio_segments: $?${clear}"
}


# I'm not sure about this flag yet, let's keep it here.
# it will add the headers of the main file to each segment files.
# IIRC, it will also make the process a bit long.
    # -flags +global_header \

# here we will separate the file into smaller section but we will search for keyframes at the end of
# each duration and split at that point.
# it seems that transcoding to .ts is more efficent than to .mkv or .mp4 (forgive me for my lack of knowledge)
# we will save the list of segments in a .concat file so that we will use it after transcoding.
function divide_video() {
    echo -e "${cyanbg}divide_video${clear}"
    # here we are going to calculate the frame_rate to be used in segment_time_delta as explained here in worse case:
    # https://ffmpeg.org/ffmpeg-all.html "For constant frame rate videos a value of 1/(2*frame_rate) should address
    # the worst case mismatch between the specified time and the time set by force_key_frames."
    # but in the several test I had, this calculation until ~10.0 had a same outcome.
    # we can keep it or ignore it
    local frame_rate=$($ffprobe_binary -v 0 -of csv=p=0 -select_streams v:0 -show_entries stream=r_frame_rate $input_file)
    local segment_time_delta=$(awk 'BEGIN{printf "%6f", 1/(2*'$frame_rate')}')
    # here we just do some split-copy but I think -copyts is also useful in some cases and it can't hurt
    # so do avoid_negative_ts
    # this is important to note that WE DO NOT COPY/transfer ANY SUBTITLES!!! because I have had problem in some
    # cases. if you want the subtitle, you can extract it easily and attach it again. so with -sn, we ignore/delete
    # the subtitles in transcoding process!
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
    grep -oE '[^ ]+.ts' $input_filename/video_segment_list.ffconcat > $input_filename/video_segment_list.txt
    echo -e "${cyanbg}create_video_filelist: $?${clear}"
}

# here we will create a directory in the nodes/worker servers similar to makedir_or_cleanup()
# before starting the main transcode process in process_video_transcode_hpc_parallel()
# for more details about the commands, see the comments before process_video_transcode_hpc_parallel()
function remote_mkdir_filename() {
    echo -e "${cyanbg}remote_mkdir_filename${clear}"
    parallel -j1 --onall \
        -S '..' --sshdelay 0.1 --workdir /mnt/data/ \
        mkdir -p {}\; rm -f {}/* ::: $input_filename
    echo -e "${cyanbg}remote_mkdir_filename: $?${clear}"
}

# here we will remove the directory we created in makedir_or_cleanup() after the main transcode
# process in process_video_transcode_hpc_parallel()
# for more details about the commands, see the comments before process_video_transcode_hpc_parallel()
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
# in the new tests, I decided to use -fps_mode passthrough not anything else. so we will have a
# synchronize output at the end. in my several test, the audio timing were just fine, but the
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

# same as above but only on local machine! we only use one of the process_video_transcode_*_parallel() functions.
# if you want to use localonly, change the function call at the end of this script to this name and
# also comment out the the remote_*_filename() calls
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

# here we create a .ffconcat file for each resolution using the first .ffconcat file.
function create_resolutions_segment_list() {
    echo -e "${cyanbg}create_resolutions_segment_list${clear}"
    for resolution in ${resolutions[@]}; do
        sed 's/\(file \)\(.*\).ts/\1transcoded_'$resolution'p_\2\.ts/g' \
        $input_filename/video_segment_list.ffconcat > $input_filename/video_segment_list_${resolution}p.ffconcat
    done
    echo -e "${cyanbg}create_resolutions_segment_list: $?${clear}"
}

# finally we assemble/concat the segments of each resolution based on the each resolution .ffconcat file.
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
# input and then map them with their sequencial index number in the fisrt input file.
# the -map start with 0 but we have the video as input in that position. so audio starts
# at 1.
function join_audios_videos() {
    echo -e "${cyanbg}join_audios_videos${clear}"
    local lambda_audio=""
    local lambda_audio_map=""
    local counter=1
    for audio_filename in $(cat $input_filename/audio_list.txt); do
        lambda_audio+=" -i $input_filename/transcoded_$audio_filename "
        lambda_audio_map+=" -map $counter:a "
        ((counter++))
    done
    parallel --bar -j 1 -k \
    $ffmpeg_binary -copyts \
    -i $input_filename/transcoded_video_$input_filename.{1}p$input_extension  \
    $lambda_audio \
    -c copy -map 0 \
    $lambda_audio_map \
    $input_filename/$input_filename.{1}p$input_extension \
    ::: ${resolutions[@]}
    echo -e "${cyanbg}join_audios_videos: $?${clear}"
}


# here we are going to clean the segments to freeup the space. because we used them
# assembling sections.
function segments_cleenup() {
    echo -e "${cyanbg}segments_cleenup${clear}"
    rm -f $input_filename/*segment_*
    echo -e "${cyanbg}segments_cleenup: $?${clear}"
}

# just a test function for now to see how much time it takes to do all spliting in HLS mode
# for all video and audio files. the master playlist is useless if you want to use it in VLC
# it seems that this is exactly what we need? 
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
    for audio_filename in $(cat $input_filename/audio_list.txt); do
        lambda_audio+=" -i $input_filename/transcoded_$audio_filename "
        lambda_audio_map+=" -map $counter:a:0 "
        lambda_audio_copy+=" -c:a:$audio_counter copy -copyts "
        var_stream_map+="a:$audio_counter,agroup:vidaud,name:audio_$audio_counter "
        ((audio_counter++))
        ((counter++))
    done
    mkdir -p $input_filename/hls
    $ffmpeg_binary \
        $lambda_video \
        $lambda_audio \
        $lambda_video_map \
        $lambda_audio_map \
        $lambda_video_copy \
        $lambda_audio_copy \
       -var_stream_map "$var_stream_map" \
       -f hls -hls_time 10 -hls_flags independent_segments \
       -hls_playlist 1 -hls_playlist_type vod -master_pl_name playlist.m3u8 \
       -hls_segment_filename "$input_filename/hls/%v/file_%04d.ts" "$input_filename/hls/%v/index.m3u8"
    echo -e "${cyanbg}make_hls: $?${clear}"
}

# here we cleanup the temporarily files in local and only the final transcooded files will remain.
function final_cleanup() {
    echo -e "${cyanbg}final_cleanup${clear}"
    rm -f $input_filename/transcoded_*
    rm -f $input_filename/audio_stream_*
    rm -f $input_filename/audio_list.txt
    echo -e "${cyanbg}final_cleanup: $?${clear}"
}

# here we run the command step by step and wait in each step to be truely completed before going to next done
# time is for debug only. we usually don't need the &wait at all. but in some cases will be helpful
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
# it will only in localonly mode
if [[ $localonly != "true" ]]; then
    time remote_mkdir_filename &
    wait
    time process_audio_transcode_hpc_parallel &
    wait
    time process_video_transcode_hpc_parallel &
    wait
    time remote_rm_filename &
    wait
else
    time transcode_audio &
    wait
    time process_video_transcode_localonly_parallel &
    wait
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

time segments_cleenup &
wait

time make_hls &
wait

time final_cleanup &
wait






# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% thinking %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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






# =================================== trash ==================================================

# -i downloads/053092d3-7845-4428-a40a-4cead148559a -y -threads 2 -map 0:a:0 -acodec aac -strict experimental -async 1 -ar 44100 -ac 2 -ab 128k -f segment -segment_time 10 -segment_list_size 0 -segment_list_flags -cache -segment_format aac -segment_list movies/053092d3-7845-4428-a40a-4cead148559a/audio/0/128k/audio.m3u8 movies/053092d3-7845-4428-a40a-4cead148559a/audio/0/128k/audio%d.aac -map 0:v:0 -pix_fmt yuv420p -vsync 1 -async 1 -vcodec h264 -vf scale=854x480 -f hls -hls_playlist_type vod -hls_time 10 -hls_list_size 0 movies/053092d3-7845-4428-a40a-4cead148559a/video/480p/index.m3u8 -map 0:v:0 -pix_fmt yuv420p -vsync 1 -async 1 -vcodec h264 -vf scale=1280x720 -f hls -hls_playlist_type vod -hls_time 10 -hls_list_size 0 movies/053092d3-7845-4428-a40a-4cead148559a/video/720p/index.m3u8


# # like previous function but each resolution has their own audio and playlist.
# function make_hls() {
#     echo -e "${cyanbg}make_hls${clear}"
#     for resolution in ${resolutions[@]}; do
#         local counter=0
#         local var_stream_map=""
#         local video_counter=0
#         local lambda_video=""
#         local lambda_video_map=""
#         local lambda_video_copy=""
#         lambda_video+=" -i $input_filename/transcoded_video_$input_filename.${resolution}p$input_extension "
#         lambda_video_map+=" -map $counter:v:0 "
#         lambda_video_copy+=" -c:v:$video_counter copy -copyts "
#         var_stream_map+="v:$video_counter,agroup:vid_${resolution}_aud,name:video_$video_counter "
#         ((video_counter++))
#         ((counter++))
#         local audio_counter=0
#         local lambda_audio=""
#         local lambda_audio_map=""
#         local lambda_audio_copy=""
#         for audio_filename in $(cat $input_filename/audio_list.txt); do
#             lambda_audio+=" -i $input_filename/transcoded_$audio_filename "
#             lambda_audio_map+=" -map $counter:a:0 "
#             lambda_audio_copy+=" -c:a:$audio_counter copy -copyts "
#             var_stream_map+="a:$audio_counter,agroup:vid_${resolution}_aud,name:audio_$audio_counter "
#             ((audio_counter++))
#             ((counter++))
#         done
#         mkdir -p "$input_filename/$resolution/"
#         $ffmpeg_binary \
#             $lambda_video \
#             $lambda_audio \
#             $lambda_video_map \
#             $lambda_audio_map \
#             $lambda_video_copy \
#             $lambda_audio_copy \
#         -var_stream_map "$var_stream_map" \
#         -f hls -hls_time 10 -hls_flags independent_segments \
#         -hls_playlist 1 -hls_playlist_type vod -master_pl_name playlist.m3u8 \
#         -hls_segment_filename "$input_filename/$resolution/%v/file_%04d.ts" "$input_filename/$resolution/%v/index.m3u8"
#     done
#     echo -e "${cyanbg}make_hls: $?${clear}"
# }

#
# function make_hls() {
#     echo -e "${cyanbg}make_hls${clear}"
#     local counter=0
#     local var_stream_map=""
#     local video_counter=0
#     local lambda_video=""
#     local lambda_video_map=""
#     local lambda_video_copy=""
#     for resolution in ${resolutions[@]}; do
#         lambda_video+="$input_filename/transcoded_video_$input_filename.$resolution$input_extension"
#         lambda_video_map+=" -map $counter:v:0 "
#         lambda_video_copy+=" -c:v:$video_counter copy -copyts "
#         var_stream_map+="v:$video_counter,agroup:vidaud,name:video_$video_counter "
#         ((video_counter++))
#         ((counter++))
#     done
#     local audio_counter=0
#     local lambda_audio=""
#     local lambda_audio_map=""
#     local lambda_audio_copy=""
#     for audio_filename in $(cat $input_filename/audio_list.txt); do
#         lambda_audio+=" -i $input_filename/transcoded_$audio_filename "
#         lambda_audio_map+=" -map $counter:a:0 "
#         lambda_audio_copy+=" -c:a:$audio_counter copy -copyts "
#         var_stream_map+="a:$audio_counter,agroup:vidaud,name:audio_$audio_counter "
#         ((audio_counter++))
#         ((counter++))
#     done
#     $ffmpeg_binary \
#         $lambda_video \
#         $lambda_audio \
#         -loop 1 \
#         -i "concat:video_low.mkv|video_med.mkv|video_high.mkv" \
#         -map 0:v \
#         -c:v libx264 -crf 23 -g [keyframe_interval] \
#         -f segment -segment_list renditions.m3u8 \
#         -segment_time [segment_duration] -segment_format mpegts \
#         -map 0:a \
#         -c:a copy \
#         -f segment -segment_list_size 1 \
#         -segment_time [segment_duration] \
#         -segment_format m4a \
#         out_%d-%d.ts \
#         out_%d-%d.m4a
# }
#
# -map 0:a:0 -f segment -segment_time 10 -segment_list_size 0 -segment_list_flags -cache -segment_format aac -segment_list name/audio/0/128k/audio.m3u8 name/audio/0/128k/audio%d.aac
# +live
# -map 0:v:0 -f hls -hls_playlist_type vod -hls_time 10 -hls_list_size 0 /video/720p/index.m3u8
#
#
# ffmpeg -i input_video.mp4 \
#        -i audio1.mp3 -map_metadata:s:a:0 -metadata:s:a:0 language \
#        -i audio2.mp3 -map_metadata:s:a:1 -metadata:s:a:1 language \
#        -i input_video_720p.mp4 \
#        -i input_video_480p.mp4 \
#        -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:v:0 -map 4:v:0 \
#        -c:v:0 copy -c:v:1 copy -c:v:2 libx264 -vf scale=854:480 \
#        -c:a copy -var_stream_map "v:0,a:0,agroup:audio,a:1,agroup:audio2,v:2,v:3" \
#        -master_pl_name master.m3u8 -f hls -hls_time 10 -hls_flags independent_segments \
#        -hls_playlist_type vod -hls_segment_filename "video_%v_%03d.ts" output.m3u8
#
#
#     ffmpeg -i input_video.mp4 -i audio1.mp3 -i audio2.mp3 -map 0:v:0 -map 1:a:0 -map 2:a:0 -c:v copy -c:a copy -var_stream_map "v:0,a:0,agroup:audio,a:1,agroup:audio2" -master_pl_name master.m3u8 -f hls -hls_time 10 -hls_flags independent_segments -hls_playlist_type vod -hls_segment_filename "video_%v_%03d.ts" output.m3u8

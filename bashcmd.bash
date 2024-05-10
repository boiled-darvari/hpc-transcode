input_file=
mkdir -p ts_segments
ffmpeg -i $input_file -c copy -sn -copyts -f segment -segment_list_type ffconcat -segment_time_delta 0.05 -reset_timestamps 1 -map 0 -segment_time 00:10:00 -segment_list ./ts_segments/segment_list.ffconcat -avoid_negative_ts 1 ./ts_segments/segment_%04d.ts


ffmpeg -i $input_file -c copy -sn -copyts -force_key_frames "expr:gte(t,n_forced*200)"  -f segment -segment_list_type ffconcat -segment_time_delta 10.0 -reset_timestamps 1 -map 0 -segment_time 200 -segment_list ./ts_segments/segment_list.ffconcat -avoid_negative_ts 1 ./ts_segments/segment_%04d.ts



cd ts_segments
ffmpeg -f concat -safe 0 -segment_time_metadata 1 -i segment_list.ffconcat -fflags +igndts -c copy -avoid_negative_ts 1 output.mkv

ffmpeg -f concat -safe 0 -i segment_list.ffconcat -c copy -avoid_negative_ts 1 output.mkv

parallel --bar -j0 ffmpeg -hide_banner -loglevel error -i $input_file -ss {2} -to {3} -c copy ./tempdir2/segment{1}.mp4 :::: paired_times.txt


-fflags +global_header

input_file=""
input_extension=".${input_file##*.}"

ffmpeg -i $input_file -c copy -sn -copyts -force_key_frames "expr:gte(t,n_forced*200)"  -f segment -segment_list_type ffconcat -segment_time_delta 5.0 -reset_timestamps 1 -map 0 -segment_time 200 -segment_list segment_list.ffconcat -flags +global_header -avoid_negative_ts 1 -hide_banner -loglevel error segment_%04d$input_extension

ffmpeg -i $input_file -c copy -sn -copyts -force_key_frames "expr:gte(t,n_forced*200)"  -f segment -segment_list_type ffconcat -segment_time_delta 10.0 -reset_timestamps 1 -map 0 -segment_time 200 -segment_list ./ts_segments/segment_list.ffconcat -avoid_negative_ts 1 ./ts_segments/segment_%04d.ts


grep -oE '[^ ]+.ts' segment_list.ffconcat > file_list.txt

grep -oE '[^ ]+'$input_extension segment_list.ffconcat > file_list.txt

root@5.56.132.247,root@5.56.132.248,root@5.56.132.249,:

parallel -j4 --bar ffmpeg -i {1} \
    -vf scale=-1:720 ./transcoded_720p_{1} \
    -vf scale=-1:480 ./transcoded_480p_{1} \
    -vf scale=-1:360 ./transcoded_360p_{1} :::: file_list.txt

parallel -j+0 --slf '..' --delay 1 --workdir /mnt/data   --transfer --return transcoded_720p_{} --return transcoded_480p_{} --return transcoded_360p_{}  --cleanup   --bar ffmpeg -i {}     -vf scale=-1:720 transcoded_720p_{}     -vf scale=-1:480 transcoded_480p_{}     -vf scale=-1:360 transcoded_360p_{} :::: file_list.txt

parallel -j+0 --delay 1 --bar ffmpeg  -i {} -c:a copy -vf scale=-2:720 transcoded_720p_{}   -c:a copy  -vf scale=-2:480 transcoded_480p_{}   -c:a copy  -vf scale=-2:360 transcoded_360p_{} :::: file_list.txt

parallel -j+0 --delay 1 --bar ffmpeg  -hide_banner -loglevel error -i {} -vf scale=-2:720 transcoded_720p_{}     -vf scale=-2:480 transcoded_480p_{}     -vf scale=-2:360 transcoded_360p_{} :::: file_list.txt

parallel -j1 -S 'root@5.56.132.247,root@5.56.132.248,root@5.56.132.249,:' --delay 1 --sshdelay 0.1 --workdir /mnt/data   --transfer --return transcoded_720p_{} --return transcoded_480p_{} --return transcoded_360p_{}  --cleanup   --bar ffmpeg  -hide_banner -loglevel error -i {}   -copyts -flags +global_header -avoid_negative_ts 1  -vf scale=-2:720 transcoded_720p_{}     -vf scale=-2:480 transcoded_480p_{}     -vf scale=-2:360 transcoded_360p_{} :::: file_list.txt

for resolution in 360p 480p 720p; do
sed 's/\(file \)\(.*\)'$input_extension'/\1transcoded_'$resolution'_\2\'$input_extension'/g' segment_list.ffconcat > segment_list_$resolution.ffconcat;done

parallel -j+0 ffmpeg -f concat -safe 0 -i segment_list_{1}.ffconcat -c copy -avoid_negative_ts 1 output_{1}$input_extension ::: 360p 480p 720p

parallel -j+0 ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i segment_list_{1}.ffconcat -c copy -avoid_negative_ts 1 output_{1}$input_extension ::: 360p 480p 720p


parallel -j0 --slf sshloginfile ffmpeg -f concat -safe 0 -i segment_list_{1}.ffconcat -c copy -avoid_negative_ts 1 output_{1}$input_extension ::: 360p 480p 720p






ffprobe -v error -skip_frame nokey -show_entries frame=pts_time -select_streams v -of csv=p=0  $input_file | sed '/^$/d; s/,$//' >> timestampskip2.txt

awk 'NR>1 {printf "%04d-%s-%s\n", ++count, prev, $0} {prev=$0}' timestampskip2.txt > paired_times.txt



parallel --bar -j+0 --colsep '-' ffmpeg -hide_banner -loglevel error -i $input_file -ss {2} -to {3} -c copy ./segment{1}$input_extension :::: paired_times.txt

parallel --bar -j4 --colsep '-' ffmpeg -hide_banner -loglevel error -i $input_file -ss {2} -to {3} -c copy ./segment{1}.ts :::: paired_times.txt

ls -1v segment*.ts > segmentlist.txt

ls -1v segment*$input_extension > segmentlist.txt

echo "ffconcat version 1.0" > segmentlist.ffconcat;sed 's/\(.*\)/file \1/g' segmentlist.txt >> segmentlist.ffconcat


time toolbox run -c fedora-toolbox-39




input_file=
mkdir -p ts_segments
ffmpeg -i $input_file -c copy -sn -copyts -f segment -segment_list_type ffconcat -segment_time_delta 0.05 -reset_timestamps 1 -map 0 -segment_time 00:10:00 -segment_list ./ts_segments/segment_list.ffconcat -avoid_negative_ts 1 ./ts_segments/segment_%04d.ts


cd ts_segments
ffmpeg -f concat -safe 0 -segment_time_metadata 1 -i segment_list.ffconcat -fflags +igndts -c copy -avoid_negative_ts 1 output.mkv


seq 1 $(echo "$KEYFRAMES" | wc -l) |
parallel -k --joblog my.log -j 0 '
  START=$(echo "$KEYFRAMES" | sed -n "{}p")
  END=$(echo "$KEYFRAMES" | sed -n "$(({}+1))p")
  ffmpeg -i $input_file -ss $START -to $END ./tempdir/segment$(printf "%03d" {}).mp4
'

echo "$KEYFRAMES" | awk '{print NR, $0}' | parallel -j+0 --colsep ' ' 'START={2}; END=$(echo "$KEYFRAMES" | sed -n "$(({}+1))p"); ffmpeg -i $input_file -ss $START -to $END  ./tempdir/segment$(printf "%03d" {}).mp4'



for i in $(seq 1 $(echo "$KEYFRAMES" | wc -l)); do     START=$(echo "$KEYFRAMES" | sed -n "${i}p");     END=$(echo "$KEYFRAMES" | sed -n "$((i+1))p");     ffmpeg -i $input_file -ss $START -to $END  ./tempdir/segment$(printf "%03d" $i).mp4; done

parallel -k --bar --colsep ' ' ffmpeg -i $input_file -ss {1} -to {2} ./tempdir/segment{#}.mp4 ::: $KEYFRAMES


for i in $(seq 1 $(echo "$KEYFRAMES" | wc -l)); do
    START=$(echo "$KEYFRAMES" | sed -n "${i}p")
    END=$(echo "$KEYFRAMES" | sed -n "$((i+1))p")
    ffmpeg -ss $START -to $END -i $TMPDIR/raw.yuv -c:v rawvideo -pix_fmt yuv420p $TMPDIR/segment$(printf "%03d" $i).yuv
done


parallel -k --bar --colsep ' ' ffmpeg -i $input_file -ss {1} -to {2} ./tempdir/segment{#}.mp4 ::: $KEYFRAMES



parallel: Warning: Only enough file handles to run 252 jobs in parallel.
parallel: Warning: Try running 'parallel -j0 -N 252 --pipe parallel -j0'
parallel: Warning: or increasing 'ulimit -n' (try: ulimit -n `ulimit -Hn`)
parallel: Warning: or increasing 'nofile' in /etc/security/limits.conf
parallel: Warning: or increasing /proc/sys/fs/file-max

input_file=""
input_extension=".${input_file##*.}"

ffprobe -v error -skip_frame nokey -show_entries frame=pts_time -select_streams v -of csv=p=0  $input_file | sed '/^$/d; s/,$//' >> timestampskip2.txt

awk 'NR>1 {printf "%04d-%s-%s\n", ++count, prev, $0} {prev=$0}' timestampskip2.txt > paired_times.txt


parallel --bar -j0 --colsep '-' ffmpeg -hide_banner -loglevel error -i $input_file -ss {2} -to {3} -c copy ./segment_{1}$input_extension :::: paired_times.txt

parallel --bar -j4 -k --colsep '-' ffmpeg -hide_banner -loglevel error -i $input_file -ss {2} -to {3} -c copy ./tempdir2/segment{1}$input_extension :::: paired_times.txt

ls ../tempdir | sort -V |less



ffmpeg -i $input_file -c copy -f segment -segment_time_delta 0.05 -reset_timestamps 1 -map 0 -segment_list ./tempdir2/output_list.txt ./tempdir2/output_%04d.mp4


ffmpeg -i input.mp4 -c copy -f segment -segment_time_delta 0.05 -reset_timestamps 1 -segment_list flags +global_header output_%03d.mp4

ffmpeg -i input.mp4 -c copy -copyts -f segment -segment_time_delta 0.05 -reset_timestamps 1 -map 0 -segment_list output_list.txt -segment_list_flags +global_header output_%03d.mp4




ffmpeg -i $input_file -c copy -f segment -segment_list_type ffconcat -segment_time_delta 0.1 -reset_timestamps 1 -map 0 -segment_list ./tmpdir2/output_list.txt ./tmpdir2/output_%04d.mp4


ffmpeg -i $input_file -c copy -copyts -force_key_frames "expr:gte(n,FRAME_RATE*0.5)" -f segment -segment_list_type ffconcat -segment_time_delta 0.1 -reset_timestamps 1 -map 0 -segment_time 0.5 -segment_list ./tmpdir2/output_list.ffcat ./tmpdir2/output_%04d.mp4


ffmpeg -safe 0 -f concat -i output_list.ffcat -c copy output_final.mkv


ffmpeg -i $input_file -c copy -copyts -force_key_frames "expr:gte(n,FRAME_RATE*0.5)" -f segment -segment_list_type ffconcat -segment_time_delta 0.1 -reset_timestamps 1 -map 0 -segment_time 0.5 -segment_list ./ts_segments/segment_list.ffconcat ./ts_segments/segment_%04d.ts

ffmpeg -i $input_file -c:v copy -an -sn -copyts -force_key_frames "expr:gte(n,FRAME_RATE*0.5)" -f segment -segment_list_type ffconcat -segment_time_delta 0.1 -reset_timestamps 1 -map 0 -segment_time 0.5 -segment_list ./ts_segments/segment_list.ffconcat ./ts_segments/segment_%04d.ts

input_file="Fantastic.Fungi.2019.1080p.WEB-DL.RARBG.MrMovie.mp4"
mkdir -p ts_segments
ffmpeg -i $input_file -c copy -f segment -segment_list_type ffconcat -segment_list ./ts_segments/segment_list.ffconcat -reset_timestamps 1 -map 0 ts_segments/segment_%04d.ts

ffmpeg -f concat -safe 0 -i ts_list.txt -c copy output.mkv

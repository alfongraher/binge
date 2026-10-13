#import "NativeMedia.h"
#import "TorrentProof.h"
#include <atomic>
#include <memory>
#include <algorithm>
#include <cstdlib>
#include <chrono>
#include <thread>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/audio_fifo.h>
#include <libswresample/swresample.h>
}
#include <vector>
#include <stdexcept>
#include <string>
static void check(int result) {
    if(result>=0)return;
    char text[AV_ERROR_MAX_STRING_SIZE];av_strerror(result,text,sizeof(text));throw std::runtime_error(text);
}
// Only unsupported audio is decoded; video and AAC remain packet copies.
class AudioPreparation {
    AVCodecContext *decoder=nullptr,*encoder=nullptr;
    SwrContext *resampler=nullptr;
    AVAudioFifo *fifo=nullptr;
    AVFrame *decoded=nullptr;
    AVFormatContext *format=nullptr;
    AVStream *input=nullptr,*output=nullptr;
    AVChannelLayout inputLayout{};
    AVSampleFormat inputFormat=AV_SAMPLE_FMT_NONE;
    int inputRate=0;
    int64_t nextPTS=AV_NOPTS_VALUE;
    int *packets=nullptr;
    void receivePackets() {
        AVPacket *packet=av_packet_alloc();if(!packet)throw std::bad_alloc();
        int result;
        while((result=avcodec_receive_packet(encoder,packet))>=0) {
            av_packet_rescale_ts(packet,encoder->time_base,output->time_base);packet->stream_index=output->index;packet->pos=-1;
            int written=av_interleaved_write_frame(format,packet);av_packet_unref(packet);
            if(written<0) { av_packet_free(&packet);check(written); }++*packets;
        }
        av_packet_free(&packet);if(result!=AVERROR(EAGAIN) && result!=AVERROR_EOF)check(result);
    }
    void encodeAvailable(bool final=false) {
        while(av_audio_fifo_size(fifo)>=encoder->frame_size || (final && av_audio_fifo_size(fifo)>0)) {
            AVFrame *frame=av_frame_alloc();if(!frame)throw std::bad_alloc();
            frame->format=encoder->sample_fmt;frame->sample_rate=encoder->sample_rate;
            int result=av_channel_layout_copy(&frame->ch_layout,&encoder->ch_layout);
            frame->nb_samples=std::min(av_audio_fifo_size(fifo),encoder->frame_size);
            if(result>=0)result=av_frame_get_buffer(frame,0);
            if(result<0) { av_frame_free(&frame);check(result); }
            int read=av_audio_fifo_read(fifo,(void**)frame->extended_data,frame->nb_samples);
            if(read!=frame->nb_samples) { av_frame_free(&frame);throw std::runtime_error("Audio preparation queue underflow"); }
            frame->pts=nextPTS;nextPTS+=frame->nb_samples;
            result=avcodec_send_frame(encoder,frame);av_frame_free(&frame);check(result);receivePackets();
        }
    }
    void processFrame(int64_t fallback) {
        int rate=decoded->sample_rate>0 ? decoded->sample_rate : decoder->sample_rate;
        if(rate<=0 || decoded->ch_layout.nb_channels<=0 || decoded->ch_layout.nb_channels>8)throw std::runtime_error("Unsupported audio channel layout");
        AVChannelLayout layout{};check(av_channel_layout_copy(&layout,&decoded->ch_layout));
        if(layout.order==AV_CHANNEL_ORDER_UNSPEC) { int channels=layout.nb_channels;av_channel_layout_uninit(&layout);av_channel_layout_default(&layout,channels); }
        auto sampleFormat=AVSampleFormat(decoded->format);
        if(!resampler || rate!=inputRate || sampleFormat!=inputFormat || av_channel_layout_compare(&layout,&inputLayout)!=0) {
            swr_free(&resampler);av_channel_layout_uninit(&inputLayout);check(av_channel_layout_copy(&inputLayout,&layout));
            inputRate=rate;inputFormat=sampleFormat;
            int result=swr_alloc_set_opts2(&resampler,&encoder->ch_layout,encoder->sample_fmt,encoder->sample_rate,&layout,sampleFormat,rate,0,nullptr);
            av_channel_layout_uninit(&layout);check(result);check(swr_init(resampler));
        } else av_channel_layout_uninit(&layout);
        auto timestamp=decoded->best_effort_timestamp!=AV_NOPTS_VALUE ? decoded->best_effort_timestamp : decoded->pts;
        if(timestamp==AV_NOPTS_VALUE)timestamp=fallback;
        if(timestamp!=AV_NOPTS_VALUE) {
            int64_t position=av_rescale_q(timestamp,input->time_base,encoder->time_base);
            if(nextPTS==AV_NOPTS_VALUE || (av_audio_fifo_size(fifo)==0 && std::llabs(position-nextPTS)>encoder->sample_rate/4))nextPTS=position;
        }
        if(nextPTS==AV_NOPTS_VALUE)nextPTS=0;
        AVFrame *converted=av_frame_alloc();if(!converted)throw std::bad_alloc();
        converted->format=encoder->sample_fmt;converted->sample_rate=encoder->sample_rate;
        int result=av_channel_layout_copy(&converted->ch_layout,&encoder->ch_layout);
        converted->nb_samples=swr_get_out_samples(resampler,decoded->nb_samples);
        if(result>=0)result=av_frame_get_buffer(converted,0);
        if(result>=0)result=swr_convert(resampler,converted->extended_data,converted->nb_samples,(const uint8_t**)decoded->extended_data,decoded->nb_samples);
        if(result>=0) {
            int count=result;result=av_audio_fifo_realloc(fifo,av_audio_fifo_size(fifo)+count);
            if(result>=0 && av_audio_fifo_write(fifo,(void**)converted->extended_data,count)!=count)result=AVERROR(ENOMEM);
        }
        av_frame_free(&converted);check(result);encodeAvailable();
    }
    void receiveFrames(int64_t fallback) {
        int result;
        while((result=avcodec_receive_frame(decoder,decoded))>=0) { processFrame(fallback);av_frame_unref(decoded); }
        if(result!=AVERROR(EAGAIN) && result!=AVERROR_EOF)check(result);
    }
public:
    ~AudioPreparation() { avcodec_free_context(&decoder);avcodec_free_context(&encoder);av_frame_free(&decoded);swr_free(&resampler);if(fifo)av_audio_fifo_free(fifo);av_channel_layout_uninit(&inputLayout); }
    void open(AVStream *source,AVFormatContext *destination,AVStream *target,int *count) {
        input=source;format=destination;output=target;packets=count;
        auto codec=avcodec_find_decoder(source->codecpar->codec_id);auto aac=avcodec_find_encoder(AV_CODEC_ID_AAC);
        if(!codec || !aac)throw std::runtime_error("This audio format is not supported yet. Choose another source.");
        decoder=avcodec_alloc_context3(codec);encoder=avcodec_alloc_context3(aac);decoded=av_frame_alloc();
        if(!decoder || !encoder || !decoded)throw std::bad_alloc();
        check(avcodec_parameters_to_context(decoder,source->codecpar));decoder->pkt_timebase=source->time_base;decoder->thread_count=1;check(avcodec_open2(decoder,codec,nullptr));
        encoder->sample_rate=48000;encoder->sample_fmt=AV_SAMPLE_FMT_FLTP;encoder->bit_rate=192000;encoder->time_base={1,48000};encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        av_channel_layout_default(&encoder->ch_layout,2);check(avcodec_open2(encoder,aac,nullptr));
        check(avcodec_parameters_from_context(output->codecpar,encoder));output->codecpar->codec_tag=0;output->time_base=encoder->time_base;
        fifo=av_audio_fifo_alloc(encoder->sample_fmt,encoder->ch_layout.nb_channels,1);if(!fifo)throw std::bad_alloc();
    }
    void send(AVPacket *packet) { check(avcodec_send_packet(decoder,packet));receiveFrames(packet->pts); }
    void finish() {
        check(avcodec_send_packet(decoder,nullptr));receiveFrames(AV_NOPTS_VALUE);
        // Supported movie audio is normally 48 kHz. Drain any resampling tail.
        if(resampler) {
            int count=swr_get_out_samples(resampler,0);
            if(count>0) {
                AVFrame *frame=av_frame_alloc();if(!frame)throw std::bad_alloc();frame->format=encoder->sample_fmt;frame->sample_rate=encoder->sample_rate;frame->nb_samples=count;
                int result=av_channel_layout_copy(&frame->ch_layout,&encoder->ch_layout);if(result>=0)result=av_frame_get_buffer(frame,0);
                if(result>=0)result=swr_convert(resampler,frame->extended_data,count,nullptr,0);
                if(result>0) { int samples=result;result=av_audio_fifo_realloc(fifo,av_audio_fifo_size(fifo)+samples);if(result>=0 && av_audio_fifo_write(fifo,(void**)frame->extended_data,samples)!=samples)result=AVERROR(ENOMEM); }
                av_frame_free(&frame);check(result);
            }
        }
        encodeAvailable(true);check(avcodec_send_frame(encoder,nullptr));receivePackets();
    }
};
// FFmpeg runs off the main thread; engine access stays on the main thread.
struct TorrentInput {
    TorrentProof *engine;
    std::atomic<bool> *cancelled;
    std::atomic<int64_t> *monitor;
    int64_t position=0;
    int64_t size=0;
};
static int readTorrent(void *opaque,uint8_t *buffer,int count) {
    auto &input=*static_cast<TorrentInput *>(opaque);
    input.monitor->store(input.position);
    if(input.position>=input.size)return AVERROR_EOF;
    count=int(std::min<int64_t>(count,input.size-input.position));
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(90);
    while(!input.cancelled->load()) {
        __block NSData *data=nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            if(!input.cancelled->load())data=[input.engine readVerifiedVideoAt:input.position length:count];
        });
        if(data.length) { memcpy(buffer,data.bytes,data.length);input.position+=data.length;return int(data.length); }
        if(std::chrono::steady_clock::now()>deadline)return AVERROR(ETIMEDOUT);
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return AVERROR_EXIT;
}
static int64_t seekTorrent(void *opaque,int64_t offset,int whence) {
    auto &input=*static_cast<TorrentInput *>(opaque);
    input.monitor->store(input.position);
    if(whence==AVSEEK_SIZE)return input.size;
    whence &= ~AVSEEK_FORCE;
    int64_t position=whence==SEEK_SET ? offset : whence==SEEK_CUR ? input.position+offset : whence==SEEK_END ? input.size+offset : -1;
    if(position<0 || position>input.size)return AVERROR(EINVAL);
    input.position=position;return position;
}
static int interrupted(void *opaque) { return static_cast<std::atomic<bool> *>(opaque)->load(); }
@implementation NativeMedia {
    std::atomic<bool> _cancelled;
    std::atomic<int> _phase,_packets;
    std::atomic<int64_t> _position;
    std::atomic<double> _duration,_sourceOffset;
}
- (NSString *)diagnostic { return [NSString stringWithFormat:@"phase %d · packets %d · input %lld",_phase.load(),_packets.load(),(long long)_position.load()]; }
- (void)cancel { _cancelled.store(true); }
- (double)duration { return _duration.load(); }
- (double)sourceOffset { return _sourceOffset.load(); }
- (void)streamTorrent:(TorrentProof *)engine directory:(NSString *)directory completion:(void (^)(NSString *))completion {
    [self streamTorrent:engine directory:directory startAt:0 completion:completion];
}
- (void)streamTorrent:(TorrentProof *)engine directory:(NSString *)directory startAt:(double)seconds completion:(void (^)(NSString *))completion {
    [self convertInput:nil engine:engine output:[directory stringByAppendingPathComponent:@"media.m3u8"] startAt:seconds completion:completion];
}
- (void)remuxInput:(NSString *)input output:(NSString *)output completion:(void (^)(NSString *))completion {
    [self convertInput:input engine:nil output:output startAt:0 completion:completion];
}
- (void)convertInput:(NSString *)input engine:(TorrentProof *)engine output:(NSString *)output startAt:(double)seconds completion:(void (^)(NSString *))completion {
    _duration.store(0);_sourceOffset.store(0);
    _cancelled.store(false);_phase.store(0);_packets.store(0);_position.store(0);
    long long size=engine ? engine.videoSize : 0;
    NSString *extension=engine.selectedFilePath.pathExtension.lowercaseString;
    const bool isMP4=[@[@"mp4",@"m4v",@"mov"] containsObject:extension];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        const bool streaming=engine!=nil;
        TorrentInput reader{engine,&self->_cancelled,&self->_position,0,size};
        AVIOContext *io=nullptr;
        AVFormatContext *source=nullptr,*destination=nullptr;
        AVCodecContext *subtitleDecoder=nullptr,*subtitleEncoder=nullptr;
        std::unique_ptr<AudioPreparation> audio;
        int audioIndex=-1;
        AVPacket *packet=av_packet_alloc();int videoPackets=0,audioPackets=0,subtitlePackets=0;
        NSString *failure=nil;
        bool pendingPacket=false;
        std::vector<AVPacket*> openingPackets;size_t openingIndex=0;
        try {
            source=avformat_alloc_context();if(!source)throw std::bad_alloc();
            source->interrupt_callback={interrupted,&self->_cancelled};
            if(streaming) {
                io=avio_alloc_context((uint8_t*)av_malloc(128*1024),128*1024,0,&reader,readTorrent,nullptr,seekTorrent);
                if(!io)throw std::bad_alloc();
                source->pb=io;source->flags |= AVFMT_FLAG_CUSTOM_IO;
                source->probesize=1024*1024;source->max_analyze_duration=3*AV_TIME_BASE;
            }
            self->_phase.store(1);
            check(avformat_open_input(&source,streaming ? nullptr : input.UTF8String,streaming ? av_find_input_format(isMP4 ? "mov" : "matroska") : nullptr,nullptr));
            self->_phase.store(2);
            self->_duration.store(source->duration>0 ? double(source->duration)/AV_TIME_BASE : 0);
            // Keep probing bounded: sparse caption tracks must not force an
            // opening scan through the entire movie.
            if(streaming) {
                // Parse a bounded opening sample so reordered video packets get
                // decode timestamps before stream copying into fragmented MP4.
                source->probesize=256*1024;
                source->max_analyze_duration=AV_TIME_BASE;
                source->max_ts_probe=10;
                source->skip_estimate_duration_from_pts=1;
                std::vector<AVDictionary*> probeOptions(source->nb_streams,nullptr);
                for(auto &option:probeOptions)av_dict_set(&option,"threads","1",0);
                int probeResult=avformat_find_stream_info(source,probeOptions.data());
                for(auto &option:probeOptions)av_dict_free(&option);
                check(probeResult);
            } else check(avformat_find_stream_info(source,nullptr));
            // MOV/MP4 duration may only become available after stream analysis.
            self->_duration.store(source->duration>0 ? double(source->duration)/AV_TIME_BASE : 0);
            check(avformat_alloc_output_context2(&destination,nullptr,streaming ? "hls" : "mp4",output.UTF8String));
            destination->avoid_negative_ts=streaming ? AVFMT_AVOID_NEG_TS_DISABLED : AVFMT_AVOID_NEG_TS_MAKE_ZERO;
            if(streaming)destination->max_interleave_delta=AV_TIME_BASE;
            std::vector<int> mapping(source->nb_streams,-1);
            int subtitleIndex=-1;bool hasVideo=false,hasAudio=false;
            for(unsigned i=0;i<source->nb_streams;++i) {
                auto in=source->streams[i];auto params=in->codecpar;
                if(params->codec_type==AVMEDIA_TYPE_VIDEO && !hasVideo) {
                    if(params->codec_id!=AV_CODEC_ID_H264 && params->codec_id!=AV_CODEC_ID_HEVC)throw std::runtime_error("This source requires unsupported video decoding. Choose H.264 or HEVC.");
                    auto out=avformat_new_stream(destination,nullptr);if(!out)throw std::bad_alloc();
                    mapping[i]=out->index;check(avcodec_parameters_copy(out->codecpar,params));out->time_base=in->time_base;
                    // Matroska often omits stream bitrate. HLS otherwise emits no
                    // playable variant until EOF, defeating progressive startup.
                    if(streaming && out->codecpar->bit_rate<=0)out->codecpar->bit_rate=source->duration>0 ? std::max<int64_t>(128000,size*8*AV_TIME_BASE/source->duration) : 4000000;
                    out->codecpar->codec_tag=params->codec_id==AV_CODEC_ID_HEVC ? MKTAG('h','v','c','1') : 0;hasVideo=true;
                } else if(params->codec_type==AVMEDIA_TYPE_AUDIO && !hasAudio) {
                    auto out=avformat_new_stream(destination,nullptr);if(!out)throw std::bad_alloc();mapping[i]=out->index;
                    if(params->codec_id==AV_CODEC_ID_AAC) { check(avcodec_parameters_copy(out->codecpar,params));out->time_base=in->time_base;out->codecpar->codec_tag=0; }
                    else { audio=std::make_unique<AudioPreparation>();audio->open(in,destination,out,&audioPackets);audioIndex=int(i); }
                    hasAudio=true;
                } else if(params->codec_type==AVMEDIA_TYPE_SUBTITLE && subtitleIndex<0) {
                    if(params->codec_id!=AV_CODEC_ID_SUBRIP && params->codec_id!=AV_CODEC_ID_WEBVTT)continue;
                    auto decoder=avcodec_find_decoder(params->codec_id);auto encoder=avcodec_find_encoder(streaming ? AV_CODEC_ID_WEBVTT : AV_CODEC_ID_MOV_TEXT);
                    if(!decoder || !encoder)throw std::runtime_error("Subtitle codecs missing");
                    subtitleDecoder=avcodec_alloc_context3(decoder);subtitleEncoder=avcodec_alloc_context3(encoder);
                    if(!subtitleDecoder || !subtitleEncoder)throw std::bad_alloc();
                    check(avcodec_parameters_to_context(subtitleDecoder,params));check(avcodec_open2(subtitleDecoder,decoder,nullptr));
                    subtitleEncoder->time_base=in->time_base;
                    for(unsigned v=0;!streaming && v<source->nb_streams;++v) if(source->streams[v]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO) {
                        av_opt_set_int(subtitleEncoder->priv_data,"height",source->streams[v]->codecpar->height,0);break;
                    }
                    if(subtitleDecoder->subtitle_header_size>0) {
                        subtitleEncoder->subtitle_header=(uint8_t*)av_mallocz(subtitleDecoder->subtitle_header_size+AV_INPUT_BUFFER_PADDING_SIZE);
                        if(!subtitleEncoder->subtitle_header)throw std::bad_alloc();
                        memcpy(subtitleEncoder->subtitle_header,subtitleDecoder->subtitle_header,subtitleDecoder->subtitle_header_size);
                        subtitleEncoder->subtitle_header_size=subtitleDecoder->subtitle_header_size;
                    }
                    check(avcodec_open2(subtitleEncoder,encoder,nullptr));
                    auto out=avformat_new_stream(destination,nullptr);if(!out)throw std::bad_alloc();
                    mapping[i]=out->index;check(avcodec_parameters_from_context(out->codecpar,subtitleEncoder));out->time_base=in->time_base;
                    auto language=av_dict_get(in->metadata,"language",nullptr,0);
                    av_dict_set(&out->metadata,"language",language ? language->value : "und",0);av_dict_set(&out->metadata,"title","Captions",0);
                    subtitleIndex=int(i);
                }
            }
            if(!hasVideo)throw std::runtime_error("No supported video stream");
            if(streaming) {
                for(unsigned i=0;i<source->nb_streams;++i) if(source->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO && mapping[i]>=0) {
                    auto video=source->streams[i];auto rate=av_guess_frame_rate(source,video,nullptr);
                    double fps=rate.den>0 ? av_q2d(rate) : 0;
                    NSString *range=video->codecpar->color_trc==AVCOL_TRC_SMPTE2084 ? @"PQ" : video->codecpar->color_trc==AVCOL_TRC_ARIB_STD_B67 ? @"HLG" : @"";
                    NSDictionary *info=@{@"frameRate":@(fps),@"videoRange":range,@"sourceContainer":isMP4 ? @"mp4" : @"mkv"};
                    NSData *data=[NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
                    [data writeToFile:[[output stringByDeletingLastPathComponent]stringByAppendingPathComponent:@"video-info.json"] atomically:YES];break;
                }
            }
            if(streaming && seconds>0) {
                check(av_seek_frame(source,-1,int64_t(seconds*AV_TIME_BASE),AVSEEK_FLAG_BACKWARD));
                // Establish the actual keyframe origin, preserving A/V timing.
                for(int attempts=0;attempts<1000;++attempts) {
                    check(av_read_frame(source,packet));
                    auto in=source->streams[packet->stream_index];
                    if(in->codecpar->codec_type==AVMEDIA_TYPE_VIDEO && mapping[packet->stream_index]>=0) {
                        auto timestamp=packet->pts!=AV_NOPTS_VALUE ? packet->pts : packet->dts;
                        if(timestamp==AV_NOPTS_VALUE)throw std::runtime_error("This source cannot establish a resume timestamp");
                        self->_sourceOffset.store(double(timestamp)*av_q2d(in->time_base));pendingPacket=true;break;
                    }
                    av_packet_unref(packet);
                }
                if(!pendingPacket)throw std::runtime_error("No video keyframe found at the saved position");
            }
            // Matroska can omit the first reordered frames' DTS after seeking.
            // Wait for the first real decode timestamp, then backfill only the
            // missing opening timestamps. Do not replace valid timing or PTS.
            int openingVideo=-1;bool foundDecodeTime=false;
            for(int count=0;count<256 && !foundDecodeTime;++count) {
                int read=pendingPacket ? 0 : av_read_frame(source,packet);pendingPacket=false;
                if(read==AVERROR_EOF)break;check(read);
                auto saved=av_packet_clone(packet);if(!saved)throw std::bad_alloc();
                openingPackets.push_back(saved);av_packet_unref(packet);
                auto in=source->streams[saved->stream_index];
                if(in->codecpar->codec_type==AVMEDIA_TYPE_VIDEO && mapping[saved->stream_index]>=0) {
                    openingVideo=saved->stream_index;
                    if(saved->dts!=AV_NOPTS_VALUE) {
                        int64_t next=saved->dts;
                        auto rate=av_guess_frame_rate(source,in,nullptr);
                        for(int index=int(openingPackets.size())-2;index>=0;--index) {
                            auto previous=openingPackets[index];if(previous->stream_index!=openingVideo)continue;
                            int64_t step=previous->duration;
                            if(step<=0 && rate.num>0 && rate.den>0)step=av_rescale_q(1,av_inv_q(rate),in->time_base);
                            if(step<=0)throw std::runtime_error("Video decode timing could not be established at this position");
                            next-=step;
                            if(previous->dts==AV_NOPTS_VALUE)previous->dts=next;
                            else next=previous->dts;
                        }
                        foundDecodeTime=true;
                    }
                }
            }
            if(openingVideo<0 || !foundDecodeTime)throw std::runtime_error("No valid video decode timestamp near this position");
            if(!(destination->oformat->flags & AVFMT_NOFILE))check(avio_open(&destination->pb,output.UTF8String,AVIO_FLAG_WRITE));
            AVDictionary *options=nullptr;
            if(streaming) {
                av_dict_set(&options,"hls_segment_type","fmp4",0);
                // HLS clients do not apply track edit-list offsets like a local
                // MP4 player. Represent frame reordering in signed composition
                // offsets instead of introducing per-track startup delays.
                av_dict_set(&options,"hls_segment_options","movflags=+negative_cts_offsets:use_editlist=0",0);
                av_dict_set(&options,"hls_time","4",0);
                av_dict_set(&options,"hls_list_size","0",0);
                av_dict_set(&options,"hls_playlist_type","event",0);
                av_dict_set(&options,"hls_flags","independent_segments+temp_file",0);
                av_dict_set(&options,"master_pl_name","master.m3u8",0);
                av_dict_set(&options,"master_pl_publish_rate","1",0);
                if(subtitleIndex>=0) {
                    auto language=av_dict_get(source->streams[subtitleIndex]->metadata,"language",nullptr,0);
                    std::string tag=language ? language->value : "und";
                    for(char c:tag)if(!((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='-')) { tag="und";break; }
                    std::string variant=(hasAudio ? "v:0,a:0,s:0,sgroup:captions,language:" : "v:0,s:0,sgroup:captions,language:")+tag;
                    av_dict_set(&options,"var_stream_map",variant.c_str(),0);
                }
            } else av_dict_set(&options,"movflags","+faststart",0);
            self->_phase.store(3);
            int header=avformat_write_header(destination,&options);av_dict_free(&options);check(header);
            self->_phase.store(4);
            int result=AVERROR_EXIT;
            while(!self->_cancelled.load()) {
                if(openingIndex<openingPackets.size()) { av_packet_move_ref(packet,openingPackets[openingIndex++]);result=0; }
                else result=av_read_frame(source,packet);
                if(result<0)break;
                self->_packets.fetch_add(1);
                int index=packet->stream_index;
                if(mapping[index]<0) { av_packet_unref(packet);continue; }
                auto in=source->streams[index];auto out=destination->streams[mapping[index]];
                if(streaming && seconds>0) {
                    int64_t shift=av_rescale_q(int64_t(self->_sourceOffset.load()*AV_TIME_BASE),AV_TIME_BASE_Q,in->time_base);
                    if(packet->pts!=AV_NOPTS_VALUE)packet->pts-=shift;
                    if(packet->dts!=AV_NOPTS_VALUE)packet->dts-=shift;
                }
                if(index==audioIndex) { audio->send(packet); }
                else if(index==subtitleIndex) {
                    AVSubtitle subtitle{};int got=0;
                    int decoded=avcodec_decode_subtitle2(subtitleDecoder,&subtitle,&got,packet);
                    if(decoded<0) { avsubtitle_free(&subtitle);check(decoded); }
                    if(got) {
                        std::vector<uint8_t> buffer(65536);
                        int length=avcodec_encode_subtitle(subtitleEncoder,buffer.data(),int(buffer.size()),&subtitle);
                        if(length<0) { avsubtitle_free(&subtitle);check(length); }
                        if(length>0) {
                            AVPacket *encoded=av_packet_alloc();if(!encoded) { avsubtitle_free(&subtitle);throw std::bad_alloc(); }
                            int allocated=av_new_packet(encoded,length);
                            if(allocated<0) { av_packet_free(&encoded);avsubtitle_free(&subtitle);check(allocated); }
                            memcpy(encoded->data,buffer.data(),length);
                            encoded->pts=av_rescale_q(packet->pts,in->time_base,out->time_base);encoded->dts=encoded->pts;
                            encoded->duration=av_rescale_q(packet->duration,in->time_base,out->time_base);encoded->stream_index=out->index;encoded->pos=-1;
                            int written=av_interleaved_write_frame(destination,encoded);av_packet_free(&encoded);avsubtitle_free(&subtitle);check(written);++subtitlePackets;
                        } else avsubtitle_free(&subtitle);
                    } else avsubtitle_free(&subtitle);
                } else {
                    av_packet_rescale_ts(packet,in->time_base,out->time_base);packet->stream_index=out->index;packet->pos=-1;
                    if(in->codecpar->codec_type==AVMEDIA_TYPE_VIDEO)++videoPackets;else ++audioPackets;
                    check(av_interleaved_write_frame(destination,packet));
                }
                av_packet_unref(packet);
            }
            if(self->_cancelled.load())throw std::runtime_error("Preparation cancelled");
            if(result!=AVERROR_EOF)check(result);
            self->_phase.store(5);
            if(audio)audio->finish();
            check(av_write_trailer(destination));
        } catch(std::exception const& error) { failure=[NSString stringWithUTF8String:error.what()]; }
        for(auto saved:openingPackets)av_packet_free(&saved);
        av_packet_free(&packet);avcodec_free_context(&subtitleDecoder);avcodec_free_context(&subtitleEncoder);
        avformat_close_input(&source);
        if(io) { av_freep(&io->buffer);avio_context_free(&io); }
        if(destination) { if(destination->pb)avio_closep(&destination->pb);avformat_free_context(destination); }
        if(failure)[[NSFileManager defaultManager]removeItemAtPath:output error:nil];
        NSDictionary *result=@{@"success":@(failure==nil),@"timingVersion":@2,@"error":failure ?: @"",@"videoPacketsCopied":@(videoPackets),@"audioPacketsCopied":@(audio ? 0 : audioPackets),@"audioPacketsWritten":@(audioPackets),@"subtitlePacketsConverted":@(subtitlePackets),@"videoReencoded":@NO,@"audioTranscoded":@(audio!=nullptr),@"duration":@(self->_duration.load()),@"sourceOffset":@(self->_sourceOffset.load())};
        NSString *json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil] encoding:NSUTF8StringEncoding];
        completion(json);
    });
}
@end

#import "TorrentProof.h"
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/session_status.hpp>
#include <libtorrent/alert_types.hpp>
#include <memory>
#include <chrono>
namespace lt = libtorrent;
@implementation TorrentProof {
    std::unique_ptr<lt::session> _seed;
    std::unique_ptr<lt::session> _client;
    lt::torrent_handle _seedHandle, _handle;
    int _selected;
    bool _connected;
    std::chrono::steady_clock::time_point _lastConnect;
    NSString *_failure;
    NSString *_cache;
    bool _external;
    bool _streaming;
    bool _metadataSaved;
    NSString *_networkAlert;
    NSString *_sessionToken;
    std::int64_t _verifiedReads;
}
- (BOOL)startWithFixture:(NSString *)fixture cache:(NSString *)cache error:(NSString **)error {
    [self stop];
    try {
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces,"127.0.0.1:0");
        settings.set_bool(lt::settings_pack::enable_dht,false);
        settings.set_bool(lt::settings_pack::enable_lsd,false);
        settings.set_bool(lt::settings_pack::enable_upnp,false);
        settings.set_bool(lt::settings_pack::enable_natpmp,false);
        settings.set_bool(lt::settings_pack::allow_multiple_connections_per_ip,true);
        _seed = std::make_unique<lt::session>(settings);
        _client = std::make_unique<lt::session>(settings);
        lt::error_code ec;
        auto info = std::make_shared<lt::torrent_info>(std::string([[fixture stringByAppendingPathComponent:@"fixture.torrent"] UTF8String]), ec);
        if(ec) throw std::runtime_error(ec.message());
        lt::add_torrent_params seed; seed.ti=info; seed.save_path=fixture.UTF8String;
        seed.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
        _seedHandle=_seed->add_torrent(seed);
        auto client=lt::parse_magnet_uri(lt::make_magnet_uri(*info));
        client.save_path=cache.UTF8String;
        client.file_priorities={lt::dont_download,lt::download_priority_t(7),lt::dont_download};
        client.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
        _handle=_client->add_torrent(client);
        _selected=1;_connected=false;_failure=nil;_external=false;_streaming=false;_metadataSaved=false;_verifiedReads=0;_cache=[cache copy];_sessionToken=NSUUID.UUID.UUIDString;
        return YES;
    } catch(std::exception const& e) { if(error)*error=[NSString stringWithUTF8String:e.what()];[self stop];return NO; }
}
- (BOOL)startExternalMagnet:(NSString *)magnet cache:(NSString *)cache error:(NSString **)error {
    return [self startMagnet:magnet cache:cache fileIndex:5 error:error];
}
- (BOOL)startMagnet:(NSString *)magnet cache:(NSString *)cache fileIndex:(int)index error:(NSString **)error {
    [self stop];
    try {
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces,"0.0.0.0:0,[::]:0");
        settings.set_bool(lt::settings_pack::enable_dht,true);
        settings.set_bool(lt::settings_pack::enable_lsd,false);
        settings.set_bool(lt::settings_pack::enable_upnp,false);
        settings.set_bool(lt::settings_pack::enable_natpmp,false);
        settings.set_int(lt::settings_pack::connections_limit,40);
        settings.set_int(lt::settings_pack::upload_rate_limit,128*1024);
        _client=std::make_unique<lt::session>(settings);
        auto params=lt::parse_magnet_uri(std::string(magnet.UTF8String));
        if(params.trackers.empty()) {
            params.trackers={"udp://tracker.opentrackr.org:1337/announce"};
            params.tracker_tiers={0};
        }
        auto cachedPath=[cache stringByAppendingPathComponent:@"cached.torrent"];
        lt::error_code cachedError;
        if([[NSFileManager defaultManager]fileExistsAtPath:cachedPath]) {
            auto cached=std::make_shared<lt::torrent_info>(std::string(cachedPath.UTF8String),cachedError);
            if(!cachedError && cached->info_hashes().v1==params.info_hashes.v1)params.ti=cached;
        }
        params.save_path=cache.UTF8String;
        params.url_seeds.clear();params.http_seeds.clear();
        params.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
        params.file_priorities=std::vector<lt::download_priority_t>(1024,lt::dont_download);
        if(index>=0 && index<1024)params.file_priorities[index]=lt::download_priority_t(1);
        _handle=_client->add_torrent(params);
        _selected=index;_connected=true;_failure=nil;_external=true;_streaming=false;_metadataSaved=false;_networkAlert=nil;_verifiedReads=0;_cache=[cache copy];_sessionToken=NSUUID.UUID.UUIDString;
        return YES;
    } catch(std::exception const& e) { if(error)*error=[NSString stringWithUTF8String:e.what()];[self stop];return NO; }
}
- (BOOL)selectedFileComplete {
    if(!_client || _selected<0)return NO;
    auto info=_handle.torrent_file();if(!info || _selected>=info->num_files())return NO;
    auto const& files=info->files();auto offset=files.file_offset(lt::file_index_t(_selected));auto size=files.file_size(lt::file_index_t(_selected));
    if(size<=0)return NO;
    auto first=offset/info->piece_length();auto last=(offset+size-1)/info->piece_length();
    auto state=_handle.status(lt::torrent_handle::query_pieces);
    if(state.pieces.size()<=last)return NO;
    for(auto p=first;p<=last;++p)if(!state.pieces[lt::piece_index_t(int(p))])return NO;
    return YES;
}
- (NSString *)selectedFilePath {
    if(!_client || !_handle.status().has_metadata)return nil;
    auto info=_handle.torrent_file();if(!info || _selected<0 || _selected>=info->num_files())return nil;
    NSString *base=[_cache stringByResolvingSymlinksInPath];
    NSString *path=[[_cache stringByAppendingPathComponent:[NSString stringWithUTF8String:info->files().file_path(lt::file_index_t(_selected)).c_str()]] stringByResolvingSymlinksInPath];
    return [path hasPrefix:[base stringByAppendingString:@"/"]] ? path : nil;
}
- (long long)videoSize {
    if(!_client || !_handle.status().has_metadata)return 0;
    auto info=_handle.torrent_file();if(!info || _selected<0 || _selected>=info->num_files())return 0;
    return info->files().file_size(lt::file_index_t(_selected));
}
- (NSData *)readVerifiedVideoAt:(long long)offset length:(int)length {
    if(!_client || offset<0 || length<=0)return nil;
    auto info=_handle.torrent_file();if(!info || _selected<0 || _selected>=info->num_files())return nil;
    auto const& files=info->files();auto size=files.file_size(lt::file_index_t(_selected));
    if(offset>=size)return [NSData data];
    length=int(std::min<std::int64_t>(length,size-offset));
    auto absolute=files.file_offset(lt::file_index_t(_selected))+offset;
    // Match the Mac's bounded demand-driven read-ahead. A small read that
    // crosses a piece boundary must not wait for two complete pieces.
    length=int(std::min<std::int64_t>(length,info->piece_length()-absolute%info->piece_length()));
    auto first=absolute/info->piece_length();
    auto fileLast=(files.file_offset(lt::file_index_t(_selected))+size-1)/info->piece_length();
    int window=std::min(8,std::max(2,4*1024*1024/info->piece_length()));
    auto last=std::min<std::int64_t>(fileLast,first+window-1);
    bool available=_handle.have_piece(lt::piece_index_t(int(first)));
    for(auto p=first;p<=last;++p) {
        auto piece=lt::piece_index_t(int(p));
        if(!_handle.have_piece(piece) && _handle.piece_priority(piece)!=lt::download_priority_t(7)) {
            _handle.piece_priority(piece,lt::download_priority_t(7));
            _handle.set_piece_deadline(piece,int(p-first)*150);
        }
    }
    if(!available)return nil;
    NSString *path=self.selectedFilePath;if(!path)return nil;
    NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:path];if(!file)return nil;
    @try { [file seekToFileOffset:offset];NSData *data=[file readDataOfLength:length];[file closeFile];if(data.length==size_t(length)){_verifiedReads+=length;return data;} } @catch(NSException *exception) { [file closeFile]; }
    return nil;
}
- (long long)fileSize:(int)index {
    if(!_client)return 0;
    auto info=_handle.torrent_file();if(!info || index<0 || index>=info->num_files())return 0;
    return info->files().file_size(lt::file_index_t(index));
}
- (BOOL)prefetchFile:(int)index {
    auto size=[self fileSize:index];if(size<=0 || size>2LL*1024*1024*1024)return NO;
    _handle.file_priority(lt::file_index_t(index),lt::download_priority_t(1));
    return YES;
}
- (BOOL)selectFile:(int)index {
    if([self fileSize:index]<=0)return NO;
    auto info=_handle.torrent_file();
    std::vector<lt::download_priority_t> wanted(info->num_files(),lt::dont_download);
    wanted[index]=lt::download_priority_t(1);
    _selected=index;_streaming=true;_failure=nil;_verifiedReads=0;
    _handle.clear_piece_deadlines();_handle.prioritize_files(wanted);_handle.resume();
    if(_handle.status().num_peers==0)_handle.clear_peers();
    _handle.set_flags(lt::torrent_flags::sequential_download);
    _connected=false;_lastConnect={};
    if(_external) { _handle.force_reannounce();_handle.force_dht_announce(); }
    return YES;
}
- (void)prepareStreaming {
    if(_client && _handle.is_valid() && _selected>=0) {
        _streaming=true;
        _handle.file_priority(lt::file_index_t(_selected),lt::download_priority_t(1));
        _handle.set_flags(lt::torrent_flags::sequential_download);
    }
}
- (void)setDownloadLimit:(int)bytesPerSecond {
    if(_client && _handle.is_valid()) {
        _handle.set_download_limit(bytesPerSecond);
        auto local=_client->get_peer_class(lt::session::local_peer_class_id);
        local.download_limit=bytesPerSecond;
        _client->set_peer_class(lt::session::local_peer_class_id,local);
    }
}
- (void)refreshDiscovery {
    if(_client && _handle.is_valid()) { _handle.force_reannounce();_handle.force_dht_announce(); }
}
- (NSString *)snapshot {
    if(!_client)return @"{\"state\":\"stopped\"}";
    if(!_external && _seed && _seedHandle.status().is_seeding && _seed->listen_port()>0) {
        auto status=_handle.status();_connected=status.num_peers>0;
        auto now=std::chrono::steady_clock::now();
        if(!_connected && !status.is_finished && now-_lastConnect>std::chrono::seconds(2)) {
            _handle.connect_peer(lt::tcp::endpoint(lt::address_v4::loopback(),_seed->listen_port()));_lastConnect=now;
        }
    }
    auto s=_handle.status();
    if(s.has_metadata) {
        auto info=_handle.torrent_file();
        if(!_metadataSaved && info) {
            try {
                auto bytes=lt::create_torrent(*info).generate_buf();
                _metadataSaved=[[NSData dataWithBytes:bytes.data() length:bytes.size()]writeToFile:[_cache stringByAppendingPathComponent:@"cached.torrent"] atomically:YES];
            } catch(std::exception const&) { }
        }
        if(_external && _selected<0) {
            std::int64_t biggest=0;
            for(int i=0;i<info->num_files();++i) {
                auto path=[NSString stringWithUTF8String:info->files().file_path(lt::file_index_t(i)).c_str()];
                auto ext=path.pathExtension.lowercaseString;
                auto size=info->files().file_size(lt::file_index_t(i));
                if(([@[@"mp4",@"m4v",@"mkv"] containsObject:ext]) && size>biggest) { biggest=size;_selected=i; }
            }
            if(_selected<0)_failure=@"No MP4 or MKV video found in this torrent.";
            else { std::vector<lt::download_priority_t> wanted(info->num_files(),lt::dont_download);wanted[_selected]=lt::download_priority_t(1);_handle.prioritize_files(wanted); }
        }
        if(_external && _selected>=info->num_files())_failure=@"Provider file index is outside this torrent.";
        auto priorities=_handle.get_file_priorities();
        if(!_external && !_streaming && priorities.size()>size_t(_selected) && priorities[_selected] != lt::download_priority_t(7)) {
            std::vector<lt::download_priority_t> wanted(info->num_files(),lt::dont_download);
            wanted[_selected]=lt::download_priority_t(7);_handle.prioritize_files(wanted);
            auto last=lt::piece_index_t((info->files().file_offset(lt::file_index_t(_selected))+info->files().file_size(lt::file_index_t(_selected))-1)/info->piece_length());
            _handle.set_piece_deadline(last,0);
        }
    }
    std::vector<lt::alert*> alerts;_client->pop_alerts(&alerts);
    for(auto a:alerts)if(auto e=lt::alert_cast<lt::torrent_error_alert>(a))_failure=[NSString stringWithUTF8String:e->error.message().c_str()];
    for(auto a:alerts)if(auto e=lt::alert_cast<lt::file_error_alert>(a))_failure=[NSString stringWithUTF8String:e->error.message().c_str()];
    for(auto a:alerts) if(lt::alert_cast<lt::tracker_error_alert>(a) || lt::alert_cast<lt::listen_failed_alert>(a)) _networkAlert=[NSString stringWithUTF8String:a->message().c_str()];
    NSDictionary *value=@{@"state":@(int(s.state)),@"paused":@(bool(_handle.flags() & lt::torrent_flags::paused)),@"uploadOnly":@(bool(_handle.flags() & lt::torrent_flags::upload_mode)),@"sessionToken":_sessionToken ?: @"",@"dhtNodes":@(_client->status().dht_nodes),@"networkAlert":_networkAlert ?: @"",@"mode":_external ? @"external" : @"loopback",@"verifiedBytesServed":@(_verifiedReads),@"metadata":@(s.has_metadata),@"seedReady":@(_seed ? _seedHandle.status().is_seeding : false),@"selectedFile":@(_selected),@"progress":@(s.progress),@"downloaded":@(s.total_done),@"rate":@(s.download_rate),@"peers":@(s.num_peers),@"finished":@(s.is_finished),@"error":_failure ?: @""};
    return [[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] encoding:NSUTF8StringEncoding];
}
- (void)selectNextFile { _selected=2;_handle.clear_piece_deadlines(); _handle.prioritize_files(std::vector<lt::download_priority_t>{lt::dont_download,lt::dont_download,lt::download_priority_t(7)}); }
- (void)stop { _client.reset();_seed.reset();_connected=false; }
@end

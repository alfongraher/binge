"""One playback session. Torrent bytes and HLS output live only in its scratch folder."""
from flow_control import producer_should_pause, paced_playlist
import json, os, sys, time, threading, signal, subprocess, mimetypes, re, secrets, shutil
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import libtorrent as lt

root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
config = json.loads(sys.stdin.readline())
token = secrets.token_hex(24)
status_file = root / 'status.json'
stop = threading.Event()
process = None
handle = None
file_path = None
file_size = 0
file_offset = 0
piece_length = 0

status_lock = threading.Lock()
status_snapshot = {}
startup_pieces = []
http_counts = {}
presentation_budgets = {}

def publish_snapshot():
    temp = root / 'status.new'
    temp.write_text(json.dumps(status_snapshot))
    temp.replace(status_file)

def status(state, **values):
    with status_lock:
        status_snapshot.update(state=state, **values)
        publish_snapshot()

def telemetry():
    reconnect_at = 0.0
    while not stop.wait(.5):
        if handle is None: continue
        try:
            state = handle.status()
            if state.num_peers == 0 and time.monotonic() - reconnect_at >= 15:
                reconnect_at = time.monotonic()
                for endpoint in params.peers: handle.connect_peer(endpoint)
                handle.force_reannounce(); handle.force_dht_announce()
            values = dict(rate=state.download_rate, peers=state.num_peers)
            if startup_pieces:
                values['bufferProgress'] = 0.5 * sum(handle.have_piece(p) for p in startup_pieces) / len(startup_pieces)
            with status_lock:
                if status_snapshot.get('state', 'metadata') not in ('ready', 'error'):
                    if 'bufferProgress' in values: values['bufferProgress'] = max(values['bufferProgress'], status_snapshot.get('bufferProgress', 0))
                    status_snapshot.update(**values)
                    publish_snapshot()
        except Exception: pass

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_HEAD(self): self.serve(False)
    def do_GET(self): self.serve(True)
    def serve(self, body):
        request_generation = globals().get('generation', 0)
        path = self.path.split('?', 1)[0]
        prefix = '/' + token + '/'
        if not path.startswith(prefix): self.send_error(404); return
        resource = path[len(prefix):]
        if resource.endswith('.m3u8'):
            http_counts[resource] = http_counts.get(resource, 0) + 1
        if resource == 'video':
            if file_path is None: self.send_error(503); return
            start, end = 0, file_size - 1
            partial = self.headers.get('Range')
            if partial:
                match = re.fullmatch(r'bytes=(\d*)-(\d*)', partial)
                if not match or not any(match.groups()): self.send_error(416); return
                a, b = match.groups()
                if a: start = int(a); end = min(int(b) if b else end, end)
                else: start = max(0, file_size - int(b))
                if start > end or start >= file_size: self.send_error(416); return
            self.send_response(206 if partial else 200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            if partial: self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
            self.end_headers()
            if not body: return
            try:
                with open(file_path, 'rb') as source:
                    offset = start
                    while offset <= end and not stop.is_set() and request_generation == globals().get('generation', 0):
                        global_offset = file_offset + offset
                        piece = global_offset // piece_length
                        amount = min(256 * 1024, end - offset + 1, piece_length - global_offset % piece_length)
                        # Request the current piece first, then a modest read-ahead window.
                        for p in range(piece, min((file_offset + file_size - 1) // piece_length + 1, piece + max(2, 4 * 1024 * 1024 // piece_length))):
                            handle.piece_priority(p, 7)
                            handle.set_piece_deadline(p, (p - piece) * 150)
                        deadline = time.monotonic() + 90
                        while not handle.have_piece(piece):
                            if stop.wait(.1) or request_generation != globals().get('generation', 0): return
                            if time.monotonic() > deadline: raise TimeoutError('No peers delivered the requested piece')
                        source.seek(offset)
                        chunk = source.read(amount)
                        if len(chunk) != amount:
                            if stop.wait(.1): return
                            continue
                        self.wfile.write(chunk)
                        offset += amount
            except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError): return
        elif re.fullmatch(r'(?:g\d+/)?(?:index\.m3u8|init\.mp4|segment\d+\.m4s)', resource):
            target = root / 'hls' / resource
            if not target.exists(): self.send_error(404); return
            data = target.read_bytes()
            if resource.endswith('.m3u8'):
                data = paced_playlist(data.decode(), presentation_budgets.get(resource, 30)).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if resource.endswith('.m3u8') else 'video/mp4')
            self.send_header('Cache-Control', 'no-store' if resource.endswith('.m3u8') else 'private, max-age=3600')
            self.send_header('Content-Length', str(len(data))); self.end_headers()
            if body:
                try: self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError): pass
        else: self.send_error(404)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}/{token}'

def shutdown(*_):
    stop.set()
    if process and process.poll() is None:
        try: os.kill(process.pid, signal.SIGCONT)
        except OSError: pass
        process.terminate()
signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

def parent_watch():
    while not stop.wait(1):
        if os.getppid() == 1: shutdown()
threading.Thread(target=parent_watch, daemon=True).start()

try:
    status('metadata')
    session = lt.session({'listen_interfaces': '0.0.0.0:0', 'connections_limit': 60,
                          'upload_rate_limit': 512 * 1024, 'close_redundant_connections': False, 'enable_upnp': False, 'enable_natpmp': False})
    params = lt.parse_magnet_uri(config['magnet']); params.save_path = str(root / 'torrent')
    # This is a demand-driven stream, not a queued whole-file download.
    params.flags &= ~(lt.torrent_flags.auto_managed | lt.torrent_flags.paused)
    handle = session.add_torrent(params)
    threading.Thread(target=telemetry, daemon=True).start()
    deadline = time.monotonic() + 120
    while not handle.has_metadata():
        if stop.wait(.2): sys.exit(0)
        if time.monotonic() > deadline: raise RuntimeError('Could not find torrent metadata. Try another source.')
    info = handle.torrent_file(); files = info.files()
    candidates = [i for i in range(files.num_files()) if Path(files.file_path(i)).suffix.lower() in ('.mp4', '.mkv', '.mov', '.m4v', '.avi', '.webm', '.ts')]
    def select_source(selected_index, requested_position):
        global index, file_path, file_size, file_offset, piece_length, startup_pieces, process, duration, start_position, tag
        index = selected_index
        file_deadline = time.monotonic() + 120
        if index is None:
            if not candidates: raise RuntimeError('This torrent has no supported video file.')
            index = max(candidates, key=files.file_size)
        if index not in candidates: raise RuntimeError('The provider selected an invalid video file.')
        file_size = files.file_size(index)
        if file_size > 40 * 1024**3: raise RuntimeError('This source exceeds the 40 GB session limit. Choose a smaller source.')
        priorities = [0] * files.num_files(); priorities[index] = 4
        handle.prioritize_files(priorities)
        file_path = (root / 'torrent' / files.file_path(index)).resolve()
        if not file_path.is_relative_to((root / 'torrent').resolve()): raise RuntimeError('Unsafe torrent file path.')
        file_offset = files.file_offset(index); piece_length = info.piece_length()
        first = file_offset // piece_length
        last = (file_offset + file_size - 1) // piece_length
        # Keep the selected file wanted between demand windows. Zeroing all other
        # pieces briefly makes this a finished torrent and loses seed connections.
        handle.prioritize_pieces([1 if first <= p <= last else 0 for p in range(info.num_pieces())])
        startup_pieces = sorted(set(list(range(first, min(last + 1, first + max(2, 4 * 1024 * 1024 // piece_length)))) + [last]))
        status("buffering", bufferProgress=0)
        for p in startup_pieces:
            handle.piece_priority(p, 7); handle.set_piece_deadline(p, 0)
        # Let disk storage create the selected sparse file before the range server opens it.
        while not file_path.exists():
            if stop.wait(.1): sys.exit(0)
            if time.monotonic() > file_deadline: raise RuntimeError('Could not create the torrent cache.')
        (root / 'hls').mkdir(exist_ok=True)
        status('buffering')
        process = subprocess.Popen([config['ffmpeg'], '-hide_banner', '-nostdin', '-rw_timeout', '90000000', '-i', base + '/video'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try: _, probe = process.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(); raise RuntimeError('Could not read video metadata. Try a source with more peers.')
        duration_match = re.search(r'Duration: (\d+):(\d+):(\d+(?:\.\d+)?)', probe.decode(errors='replace'))
        duration = int(duration_match[1]) * 3600 + int(duration_match[2]) * 60 + float(duration_match[3]) if duration_match else 0
        start_position = min(max(0, requested_position), max(0, duration - 1))
        status('buffering', duration=duration, offset=start_position, fileSize=file_size, fileIdx=index)
        codec = re.search(r'Video: (h264|hevc)\b', probe.decode(errors='replace'))
        if not codec: raise RuntimeError('This first player supports H.264 and HEVC video. Choose another source.')
        tag = ['-tag:v', 'hvc1'] if codec.group(1) == 'hevc' else []
    select_source(config.get('fileIdx'), float(config.get('startPosition', 0)))
    pending_index = None
    prefetched_index = None
    prefetched_pieces = []
    seek_id = 0
    control = {}
    generation = 0
    while not stop.is_set():
        generation += 1
        if generation > 1: handle.clear_piece_deadlines()
        if pending_index is not None:
            status('buffering', seekID=seek_id, duration=0, url=None, offset=0, bufferProgress=0)
            select_source(pending_index, start_position)
            pending_index = None; prefetched_index = None; prefetched_pieces = []
        output = root / 'hls' / f'g{generation}'
        output.mkdir()
        session.resume(); handle.set_download_limit(0); handle.set_upload_limit(512 * 1024)
        # Preserve wanted pieces and peer connections; briefly clearing all priorities
        # can disconnect the only useful peer before the new range is requested.
        status('buffering', bufferProgress=0, offset=start_position, generatedUntil=start_position, seekID=seek_id, generation=generation, ended=False, url=None)
        process = subprocess.Popen([config['ffmpeg'], '-hide_banner', '-loglevel', 'error', '-nostdin',
            '-rw_timeout', '90000000', '-readrate', '6', *(['-noaccurate_seek', '-ss', str(start_position)] if start_position > 0 else []), '-i', base + '/video',
            '-map', '0:v:0', '-map', '0:a:0?', '-c:v', 'copy', *tag,
            '-af', 'aresample=async=1', '-avoid_negative_ts', 'make_zero', '-c:a', 'aac', '-b:a', '192k', '-ac', '2', '-sn',
            '-f', 'hls', '-hls_time', '4', '-hls_playlist_type', 'event', '-hls_segment_type', 'fmp4',
            '-hls_flags', 'independent_segments+temp_file', '-hls_segment_filename', str(output / 'segment%06d.m4s'),
            str(output / 'index.m3u8')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ready = False
        presentation_elapsed = 0.0
        presentation_tick = time.monotonic()
        presentation_key = f'g{generation}/index.m3u8'
        presentation_budgets[presentation_key] = 30
        started = time.monotonic()
        producer_paused = False
        while not stop.wait(.5):
            control_file = root / 'control.json'
            try:
                control = json.loads(control_file.read_text()) if control_file.exists() else {}
            except (OSError, ValueError):
                control = {}
            now = time.monotonic()
            if ready and not bool(control.get('paused')):
                presentation_elapsed += now - presentation_tick
            presentation_tick = now
            presentation_budgets[presentation_key] = 30 + presentation_elapsed
            next_index = control.get('prefetchFileIdx')
            if next_index in candidates and next_index != index and next_index != prefetched_index:
                prefetched_index = next_index
                next_first = files.file_offset(next_index) // piece_length
                next_last = (files.file_offset(next_index) + files.file_size(next_index) - 1) // piece_length
                prefetched_pieces = sorted(set(range(next_first, min(next_last + 1, next_first + max(2, 4 * 1024 * 1024 // piece_length)))) | {next_last})
                prefetch_priorities = [0] * files.num_files(); prefetch_priorities[index] = 4; prefetch_priorities[next_index] = 1
                handle.prioritize_files(prefetch_priorities)
                piece_priorities = [1 if file_offset // piece_length <= p <= (file_offset + file_size - 1) // piece_length else 0 for p in range(info.num_pieces())]
                for p in prefetched_pieces: piece_priorities[p] = 7
                handle.prioritize_pieces(piece_priorities)
                for p in prefetched_pieces: handle.set_piece_deadline(p, 5000 + max(0, p - next_first) * 150)
            requested = int(control.get('seekID', 0))
            if requested > seek_id:
                seek_id = requested
                requested_index = control.get('fileIdx', index)
                if requested_index != index:
                    pending_index = requested_index
                    start_position = max(0, float(control['seekPosition']))
                else:
                    start_position = min(max(0, float(control['seekPosition'])), max(0, duration - 1))
                if process.poll() is None:
                    os.kill(process.pid, signal.SIGCONT)
                    process.terminate()
                    try: process.wait(timeout=3)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
                break
            playlist = output / 'index.m3u8'
            generated = 0
            ended = False
            if playlist.exists():
                text = playlist.read_text()
                generated = sum(float(value) for value in re.findall(r'#EXTINF:([0-9.]+)', text))
                ended = '#EXT-X-ENDLIST' in text
                if generated < 30 and not ended:
                    status('buffering', bufferProgress=min(1, generated / 30))
                if generated >= 30 or ended:
                    ready = True
                    state = handle.status()
                    status('ready', generatedUntil=generated + start_position, url=base + f'/g{generation}/index.m3u8', rate=state.download_rate, peers=state.num_peers, bufferProgress=1, ended=ended, playlistRequests=dict(http_counts))
            should_pause = ready and producer_should_pause(control, generated, producer_paused)
            if should_pause != producer_paused and process.poll() is None:
                os.kill(process.pid, signal.SIGSTOP if should_pause else signal.SIGCONT)
                # Keep useful peers connected while production is throttled.
                handle.set_download_limit(1024 if should_pause else 0)
                handle.set_upload_limit(1024 if should_pause else 512 * 1024)
                producer_paused = should_pause
            if producer_paused:
                prefetch_missing = any(not handle.have_piece(p) for p in prefetched_pieces)
                handle.set_download_limit(512 * 1024 if prefetch_missing else 1024)
            if process.poll() is not None:
                if process.returncode != 0: raise RuntimeError('This source could not be remuxed. Try an H.264 or HEVC source.')
                if not ready: raise RuntimeError('The source produced no playable video.')
            if not ready and time.monotonic() - started > 180:
                raise RuntimeError('Buffering timed out. Try a source with more peers.')
        # The native player has detached the old generation before requesting this one.
        shutil.rmtree(output, ignore_errors=True)

except Exception as error:
    status('error', message=str(error) if isinstance(error, RuntimeError) else 'Torrent playback failed. Try another source.')
    if process and process.poll() is None: process.terminate()
    while not stop.wait(.5): pass
finally:
    shutdown()
    if process:
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    if handle: session.remove_torrent(handle)
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)

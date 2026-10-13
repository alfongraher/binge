"""Local-only integration test using generated video and a localhost torrent seeder."""
import json, os, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path
import libtorrent as lt

project = Path(__file__).resolve().parents[1]
ffmpeg = project / '.runtime/node_modules/ffmpeg-static/ffmpeg'
with tempfile.TemporaryDirectory(prefix='drift-engine-check-') as tmp:
    root = Path(tmp); seed = root / 'seed'; seed.mkdir()
    (seed / 'pack').mkdir()
    video = seed / 'pack/sample.mkv'
    subprocess.run([str(ffmpeg), '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
                    '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '240' if '--seek' in sys.argv else '16', '-c:v', 'libx265' if '--hevc' in sys.argv else 'libx264', '-pix_fmt', 'yuv420p10le' if '--hevc' in sys.argv else 'yuv420p', '-g', '48', '-c:a', 'aac', str(video)], check=True)
    (seed / 'pack/readme.txt').write_text('Generated test torrent')
    storage = lt.file_storage(); storage.add_file('pack/readme.txt', (seed / 'pack/readme.txt').stat().st_size); storage.add_file('pack/sample.mkv', video.stat().st_size)
    if '--episodes' in sys.argv:
        import shutil
        shutil.copyfile(video, seed / 'pack/next.mkv')
        storage.add_file('pack/next.mkv', video.stat().st_size)
    creator = lt.create_torrent(storage, 16 * 1024, flags=lt.create_torrent.v1_only); lt.set_piece_hashes(creator, str(seed))
    info = lt.torrent_info(creator.generate())
    session = lt.session({'listen_interfaces': '127.0.0.1:0', 'enable_dht': False, 'enable_lsd': False, 'enable_upnp': False, 'enable_natpmp': False})
    seeder = session.add_torrent({'ti': info, 'save_path': str(seed)})
    seeder.unset_flags(lt.torrent_flags.auto_managed); seeder.resume()
    deadline = time.monotonic() + 20
    while not seeder.status().is_seeding:
        if time.monotonic() > deadline: raise RuntimeError('Local seeder did not start')
        time.sleep(.1)
    scratch = root / 'playback'
    process = subprocess.Popen([sys.executable, str(project / 'Engine/torrent_stream.py'), str(scratch)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    magnet = lt.make_magnet_uri(info) + '&x.pe=127.0.0.1:' + str(session.listen_port())
    process.stdin.write(json.dumps({'magnet': magnet, 'fileIdx': 1, 'startPosition': 4.75, 'ffmpeg': str(ffmpeg)}) + '\n'); process.stdin.close()
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            status = json.loads((scratch / 'status.json').read_text()) if (scratch / 'status.json').exists() else {}
            if status.get('state') == 'error': raise RuntimeError(status['message'])
            if status.get('state') == 'ready':
                with urllib.request.urlopen(status['url'], timeout=5) as response: playlist = response.read().decode()
                assert '#EXTM3U' in playlist and ('.m4s' in playlist or '.ts' in playlist)
                assert status['offset'] == 4.75
                assert status['bufferProgress'] == 1 and status['peers'] >= 0 and status['rate'] >= 0
                segment = next(line for line in playlist.splitlines() if line.endswith(('.m4s', '.ts')))
                with urllib.request.urlopen(status['url'].rsplit('/', 1)[0] + '/' + segment, timeout=5) as response:
                    assert len(response.read()) > 100
                # Non-keyframe resume must preserve a common audio/video timeline.
                crc = subprocess.run([str(ffmpeg), '-v', 'error', '-copyts', '-start_at_zero', '-i', status['url'], '-map', '0:v:0', '-map', '0:a:0', '-t', '1', '-c:v', 'rawvideo', '-c:a', 'pcm_s16le', '-f', 'framecrc', '-'], capture_output=True, text=True, check=True, timeout=20).stdout
                bases, first = {}, {}
                for line in crc.splitlines():
                    if line.startswith('#tb '):
                        track, fraction = line[4:].split(': '); numerator, denominator = fraction.split('/')
                        bases[int(track)] = float(numerator) / float(denominator)
                    elif line and not line.startswith('#'):
                        fields = line.split(','); track = int(fields[0]); first.setdefault(track, int(fields[2]) * bases[track])
                assert 0 in first and 1 in first and abs(first[0] - first[1]) < .2, ('Audio/video start mismatch', first, crc[:1000])
                print('Non-keyframe resume audio/video timestamps aligned:', first)
                (scratch / 'control.json').write_text(json.dumps({'paused': True, 'position': 0}))
                time.sleep(0.8)
                assert process.poll() is None and (scratch / 'hls').exists(), 'Returning to sources retains one session'
                (scratch / 'control.json').write_text(json.dumps({'paused': False, 'position': 0}))
                if len(sys.argv) > 1:
                    try: subprocess.run([sys.argv[1], status['url'], '35' if '--long' in sys.argv else '0.5'], check=True, timeout=90)
                    except Exception:
                        print('Engine at native stall:', json.loads((scratch / 'status.json').read_text()))
                        raise
                if '--seek' in sys.argv:
                    previous_url = status['url']
                    status = json.loads((scratch / 'status.json').read_text())
                    assert status['generatedUntil'] < 210, 'Seek target must be outside the original buffer'
                    cached = scratch / 'torrent/pack/sample.mkv'
                    inode = cached.stat().st_ino
                    (scratch / 'control.json').write_text(json.dumps({'paused': True, 'position': 0, 'seekID': 1, 'seekPosition': 210.75}))
                    time.sleep(.1)
                    (scratch / 'control.json').write_text(json.dumps({'paused': True, 'position': 0, 'seekID': 2, 'seekPosition': 220.75}))
                    seek_deadline = time.monotonic() + 60
                    while time.monotonic() < seek_deadline:
                        status = json.loads((scratch / 'status.json').read_text())
                        if status.get('state') == 'error': raise RuntimeError(status['message'])
                        if status.get('seekID') == 2 and status.get('state') == 'ready': break
                        time.sleep(.2)
                    else: raise RuntimeError('Unbuffered seek did not become ready: ' + str(status))
                    assert status['offset'] == 220.75 and status['url'] != previous_url
                    assert cached.stat().st_ino == inode, 'Seeking must retain the original torrent cache'
                    (scratch / 'control.json').write_text(json.dumps({'paused': False, 'position': 0, 'seekID': 2, 'seekPosition': 220.75}))
                    if len(sys.argv) > 1: subprocess.run([sys.argv[1], status['url']], check=True, timeout=25)
                    print('Unbuffered seek, latest request wins, paused seek preparation, fresh playlist, native playback, and cache reuse passed.')
                if '--episodes' in sys.argv:
                    old_url = status['url']
                    cached = scratch / 'torrent/pack/sample.mkv'; inode = cached.stat().st_ino
                    (scratch / 'control.json').write_text(json.dumps({'paused': False, 'position': 0, 'prefetchFileIdx': 2}))
                    time.sleep(1)
                    (scratch / 'control.json').write_text(json.dumps({'paused': False, 'position': 0, 'fileIdx': 2, 'seekID': 3, 'seekPosition': 0}))
                    until = time.monotonic() + 60
                    while time.monotonic() < until:
                        status = json.loads((scratch / 'status.json').read_text())
                        if status.get('state') == 'error': raise RuntimeError(status['message'])
                        if status.get('state') == 'ready' and status.get('seekID') == 3 and status.get('fileIdx') == 2: break
                        time.sleep(.2)
                    else: raise RuntimeError('Episode switch timed out: ' + str(status))
                    assert status['url'] != old_url and cached.stat().st_ino == inode and process.poll() is None
                    assert status['offset'] == 0
                    if len(sys.argv) > 1: subprocess.run([sys.argv[1], status['url']], check=True, timeout=25)
                    print('Next episode reused the same torrent worker and cached pack successfully.')
                print('Local torrent metadata, indexed file streaming, HLS remux, and segment delivery passed.')
                break
            if process.poll() is not None: raise RuntimeError(process.stderr.read())
            time.sleep(.2)
        else: raise RuntimeError('Playback test timed out: ' + str(status) + '; seeder=' + str(seeder.status().state) + ', peers=' + str(seeder.status().num_peers) + ', paused=' + str(bool(seeder.flags() & lt.torrent_flags.paused)) + '; alerts=' + str([a.message() for a in session.pop_alerts()][-6:]))
    finally:
        process.terminate()
        process.wait(timeout=10)
        assert process.poll() is not None
        assert not scratch.exists(), 'Stopping the session removes its cache'
        print('Torrent worker shutdown passed.')

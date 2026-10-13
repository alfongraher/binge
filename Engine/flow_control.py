"""Bounded producer flow control, independent of the native playback clock."""
def producer_should_pause(control, generated, already_paused):
    if bool(control.get('paused')):
        return True
    ahead = generated - max(0, float(control.get('position', 0)))
    limit = 300 if bool(control.get('recovering')) else (90 if already_paused else 180)
    return ahead > limit


def paced_playlist(text, budget):
    """Reveal real cached segments at playback pace so an EVENT playlist stays live.

    Production may pause far ahead of the playhead. Exposing its whole burst at
    once then freezing the manifest makes AVPlayer reject it as a stale stream.
    """
    lines = text.splitlines()
    headers, segments = [], []
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith('#EXTINF:') and index + 1 < len(lines):
            length = float(line.split(':', 1)[1].split(',', 1)[0])
            segments.append((length, [line, lines[index + 1]])); index += 2
        else:
            if line != '#EXT-X-ENDLIST': headers.append(line)
            index += 1
    if not any(line.startswith("#EXT-X-START:") for line in headers):
        headers.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
    visible, total = [], 0.0
    for length, chunk in segments:
        if visible and total + length > budget + .001: break
        total += length; visible.extend(chunk)
    if '#EXT-X-ENDLIST' in lines and len(visible) == 2 * len(segments):
        visible.append('#EXT-X-ENDLIST')
    return '\n'.join(headers + visible) + '\n'

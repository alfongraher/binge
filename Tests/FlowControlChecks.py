import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Engine'))
from flow_control import producer_should_pause
assert producer_should_pause({'paused': False, 'position': 142}, 340, False)
assert not producer_should_pause({'paused': False, 'position': 142, 'recovering': True}, 340, True)
assert producer_should_pause({'paused': True, 'position': 142, 'recovering': True}, 340, True)
assert producer_should_pause({'paused': False, 'position': 142, 'recovering': True}, 500, True)
assert not producer_should_pause({'paused': False, 'position': 270}, 340, True)
print('Suspended producer recovery, explicit pause, buffer limit, and hysteresis checks passed.')

from flow_control import paced_playlist
text = '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-PLAYLIST-TYPE:EVENT\n' + ''.join(f'#EXTINF:4.0,\nsegment{i:06d}.m4s\n' for i in range(10)) + '#EXT-X-ENDLIST\n'
first = paced_playlist(text, 30)
assert '#EXT-X-START:TIME-OFFSET=0,PRECISE=YES' in first
assert first.count('#EXTINF:') == 7 and '#EXT-X-ENDLIST' not in first
second = paced_playlist(text, 34)
assert second.count('#EXTINF:') == 8 and 'segment000007.m4s' in second
assert '#EXT-X-ENDLIST' in paced_playlist(text, 40)
print('Paced cached playlist growth and actual final segment checks passed.')

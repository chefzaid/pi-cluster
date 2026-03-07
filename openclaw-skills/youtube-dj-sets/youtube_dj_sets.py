#!/usr/bin/env python3
"""
YouTube DJ Sets Curator — Weekly workflow

Searches YouTube for DJ sets (>50 min) from a curated list of artists,
labels and genres, then adds up to 5 new videos to the "DJ Sets" playlist.

Requires env vars: YOUTUBE_CLIENT_ID, YOUTUBE_CLIENT_SECRET
OAuth refresh token stored at ~/.openclaw/workspace/.youtube-token.json
"""
import os
import sys
import json
import random
import time
import urllib.request
import urllib.parse
import urllib.error
from datetime import datetime, timedelta

# ── Config ────────────────────────────────────────────────────────────
CLIENT_ID = os.environ.get('YOUTUBE_CLIENT_ID')
CLIENT_SECRET = os.environ.get('YOUTUBE_CLIENT_SECRET')
TOKEN_FILE = os.path.expanduser('~/.openclaw/workspace/.youtube-token.json')
API_BASE = 'https://www.googleapis.com/youtube/v3'

# ── Artist / genre / label seeds ─────────────────────────────────────
ARTISTS = [
    "Miss Monique", "Koralova", "NTO", "Teho", "Sultan + Shepard",
    "Lane 8", "Ben Bohmer", "French 79", "Adriatique", "WhoMadeWho",
    "Tale of Us", "Anyma", "Argy", "Artbat", "Monolink",
    "Fideles", "Rufus du Sol", "Elderbrook", "Bob Moses", "Massano",
    "Mind Against", "Nora Van Elken", "Indira Paganotto", "Tiesto",
    "Armin van Buuren", "Charlotte de Witte",
]

LABELS = ["Afterlife", "Cercle", "Alter K", "Siona Records"]

GENRE_TERMS = [
    "DJ set", "live set", "mix", "melodic techno set",
    "afro house set", "progressive house set", "deep house set",
    "techno set", "trance set", "organic house set",
]


# ── OAuth helpers ─────────────────────────────────────────────────────
def load_token():
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, 'r') as f:
            return json.load(f)
    return None


def save_token(token):
    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    with open(TOKEN_FILE, 'w') as f:
        json.dump(token, f)


def refresh_access_token(refresh_token):
    data = urllib.parse.urlencode({
        'client_id': CLIENT_ID,
        'client_secret': CLIENT_SECRET,
        'refresh_token': refresh_token,
        'grant_type': 'refresh_token',
    }).encode()
    req = urllib.request.Request(
        'https://oauth2.googleapis.com/token', data=data, method='POST')
    req.add_header('Content-Type', 'application/x-www-form-urlencoded')
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
            return result.get('access_token')
    except urllib.error.HTTPError as e:
        print(f"Token refresh failed: {e.read().decode()}")
        return None


def get_access_token():
    token_data = load_token()
    if token_data and 'refresh_token' in token_data:
        access_token = refresh_access_token(token_data['refresh_token'])
        if access_token:
            return access_token
    print("ERROR: No valid refresh token. Re-authorise via OAuth flow.")
    return None


# ── YouTube API helpers ───────────────────────────────────────────────
def api_call(endpoint, params=None, access_token=None, method='GET', data=None):
    url = f"{API_BASE}/{endpoint}"
    if params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, data=data, method=method)
    if access_token:
        req.add_header('Authorization', f'Bearer {access_token}')
    req.add_header('Accept', 'application/json')
    if data:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        print(f"API error {e.code}: {e.read().decode()}")
        return None


def parse_duration(iso_duration):
    """Parse ISO 8601 duration (PT#H#M#S) to minutes."""
    d = iso_duration.replace('PT', '')
    hours = minutes = seconds = 0
    if 'H' in d:
        parts = d.split('H'); hours = int(parts[0]); d = parts[1] if len(parts) > 1 else ''
    if 'M' in d:
        parts = d.split('M'); minutes = int(parts[0]); d = parts[1] if len(parts) > 1 else ''
    if 'S' in d:
        seconds = int(d.split('S')[0])
    return hours * 60 + minutes + seconds / 60


def search_videos(access_token, query, published_after=None, order='relevance'):
    """Search YouTube. Uses relevance order by default for broader results."""
    params = {
        'part': 'snippet',
        'type': 'video',
        'videoDuration': 'long',   # >20 min
        'q': query,
        'order': order,
        'maxResults': 25,
    }
    if published_after:
        params['publishedAfter'] = published_after
    return api_call('search', params, access_token)


def get_video_details(access_token, video_ids):
    if not video_ids:
        return []
    params = {'part': 'contentDetails,snippet', 'id': ','.join(video_ids)}
    result = api_call('videos', params, access_token)
    return result.get('items', []) if result else []


def get_playlist(access_token, playlist_name="DJ Sets"):
    result = api_call('playlists', {'part': 'snippet', 'mine': 'true', 'maxResults': '50'}, access_token)
    if result:
        for pl in result.get('items', []):
            if pl['snippet']['title'] == playlist_name:
                print(f"Found playlist: {playlist_name} (ID: {pl['id']})")
                return pl['id']
    # Create
    data = json.dumps({
        'snippet': {'title': playlist_name, 'description': 'Curated DJ sets — techno, house, trance and more'},
        'status': {'privacyStatus': 'private'},
    }).encode()
    result = api_call('playlists', {'part': 'snippet,status'}, access_token, 'POST', data)
    if result:
        print(f"Created playlist: {playlist_name} (ID: {result['id']})")
        return result['id']
    return None


def get_playlist_videos(access_token, playlist_id):
    video_ids = set()
    next_page = None
    while True:
        params = {'part': 'snippet', 'playlistId': playlist_id, 'maxResults': '50'}
        if next_page:
            params['pageToken'] = next_page
        result = api_call('playlistItems', params, access_token)
        if not result:
            break
        for item in result.get('items', []):
            res = item.get('snippet', {}).get('resourceId', {})
            if res.get('kind') == 'youtube#video':
                video_ids.add(res['videoId'])
        next_page = result.get('nextPageToken')
        if not next_page:
            break
    return video_ids


def add_to_playlist(access_token, playlist_id, video_id):
    data = json.dumps({
        'snippet': {
            'playlistId': playlist_id,
            'resourceId': {'kind': 'youtube#video', 'videoId': video_id},
        }
    }).encode()
    return api_call('playlistItems', {'part': 'snippet'}, access_token, 'POST', data) is not None


# ── Main workflow ─────────────────────────────────────────────────────
def main():
    print("=" * 60)
    print("YouTube DJ Sets Curator — Weekly Run")
    print("=" * 60)
    print()

    if not CLIENT_ID or not CLIENT_SECRET:
        print("ERROR: YOUTUBE_CLIENT_ID / YOUTUBE_CLIENT_SECRET not set.")
        sys.exit(1)

    access_token = get_access_token()
    if not access_token:
        sys.exit(1)
    print("Authenticated successfully!\n")

    playlist_id = get_playlist(access_token)
    if not playlist_id:
        print("Failed to get/create playlist."); sys.exit(1)

    print("Checking existing playlist videos...")
    existing_videos = get_playlist_videos(access_token, playlist_id)
    print(f"Found {len(existing_videos)} existing videos in playlist\n")

    # ── Build search queries with mixed time windows ──────────────────
    # Use a blend of time windows so results aren't all from today.
    now = datetime.utcnow()
    time_windows = [
        ("7d",  (now - timedelta(days=7)).isoformat("T") + "Z"),    # last week
        ("90d", (now - timedelta(days=90)).isoformat("T") + "Z"),   # last 3 months
        (None,  None),                                               # all time (no filter)
    ]

    selected_artists = random.sample(ARTISTS, min(5, len(ARTISTS)))
    selected_labels = random.sample(LABELS, min(2, len(LABELS)))

    # Build (query, publishedAfter, order) tuples
    searches = []

    # Artist queries — use relevance + no time filter (captures classic & new)
    for artist in selected_artists[:3]:
        searches.append((f"{artist} DJ set full", None, 'relevance'))
        searches.append((f"{artist} live set", None, 'relevance'))

    # Label queries — recent (last 90 days) + date order for freshness
    for label in selected_labels:
        searches.append((f"{label} DJ set", time_windows[1][1], 'date'))

    # Genre queries — mix of time windows and orders
    genre_queries = [
        "melodic techno DJ set",
        "progressive house mix",
        "afro house DJ set",
        "techno live set",
        "deep house mix",
        "organic house DJ set",
    ]
    for gq in genre_queries:
        window_label, published_after = random.choice(time_windows)
        order = 'date' if published_after else 'relevance'
        searches.append((gq, published_after, order))

    print(f"Search queries ({len(searches)}):")
    for q, pa, o in searches:
        tag = f" [since {pa[:10]}]" if pa else " [all time]"
        print(f"  - {q}{tag} (order={o})")
    print()

    # ── Collect candidates ────────────────────────────────────────────
    candidate_videos = []
    seen_ids = set()

    for query, published_after, order in searches:
        print(f"Searching: {query}...")
        result = search_videos(access_token, query, published_after, order)
        if result and 'items' in result:
            for item in result['items']:
                vid = item['id']['videoId']
                if vid not in seen_ids:
                    seen_ids.add(vid)
                    candidate_videos.append({
                        'id': vid,
                        'title': item['snippet']['title'],
                        'channel': item['snippet']['channelTitle'],
                        'published': item['snippet']['publishedAt'],
                    })
        time.sleep(0.5)

    print(f"\nFound {len(candidate_videos)} unique candidate videos")

    # ── Filter by duration (>= 50 min) ───────────────────────────────
    qualifying = []
    for i in range(0, len(candidate_videos), 50):
        batch = candidate_videos[i:i+50]
        details = get_video_details(access_token, [v['id'] for v in batch])
        for detail in details:
            dur = detail.get('contentDetails', {}).get('duration', 'PT0S')
            mins = parse_duration(dur)
            if mins >= 50:
                for c in batch:
                    if c['id'] == detail['id']:
                        c['duration_min'] = mins
                        qualifying.append(c)
                        break
        time.sleep(0.5)

    print(f"Found {len(qualifying)} videos >= 50 minutes")

    # ── Remove duplicates already in playlist ─────────────────────────
    new_videos = [v for v in qualifying if v['id'] not in existing_videos]

    # Sort by a mix: shuffle to avoid always picking the newest
    random.shuffle(new_videos)

    print(f"Found {len(new_videos)} new videos not in playlist\n")

    if not new_videos:
        print("No new videos to add this week.")
        return

    # ── Pick 5 diverse videos ─────────────────────────────────────────
    videos_to_add = []
    channels_used = set()

    for video in new_videos:
        if len(videos_to_add) >= 5:
            break
        ch = video['channel']
        if ch not in channels_used:
            videos_to_add.append(video)
            channels_used.add(ch)

    # If not enough from unique channels, fill remaining
    if len(videos_to_add) < 5:
        for video in new_videos:
            if len(videos_to_add) >= 5:
                break
            if video not in videos_to_add:
                videos_to_add.append(video)

    # ── Show & add ────────────────────────────────────────────────────
    print("Selected videos:")
    for i, v in enumerate(videos_to_add, 1):
        print(f"  {i}. {v['title'][:70]}")
        print(f"     Channel: {v['channel']} | {v['duration_min']:.0f} min | {v['published'][:10]}")
    print()

    print(f"Adding {len(videos_to_add)} videos to playlist:")
    added_count = 0
    for video in videos_to_add:
        print(f"  Adding: {video['title'][:60]}...")
        if add_to_playlist(access_token, playlist_id, video['id']):
            print(f"    ✔ Added")
            added_count += 1
        else:
            print(f"    ✗ Failed")
        time.sleep(0.5)

    print(f"\n{'=' * 60}")
    print(f"Done — added {added_count} new DJ sets to the playlist.")
    print(f"{'=' * 60}")

    # ── Log to daily memory ───────────────────────────────────────────
    memory_dir = os.path.expanduser('~/.openclaw/workspace/memory')
    os.makedirs(memory_dir, exist_ok=True)
    today = datetime.utcnow().strftime('%Y-%m-%d')
    memory_file = os.path.join(memory_dir, f'{today}.md')

    with open(memory_file, 'a') as f:
        f.write(f"\n## YouTube DJ Sets Curator — {datetime.utcnow().strftime('%H:%M')} UTC\n\n")
        f.write(f"Added {added_count} new DJ sets to the 'DJ Sets' playlist:\n\n")
        for v in videos_to_add[:added_count]:
            f.write(f"- [{v['title']}](https://youtube.com/watch?v={v['id']})\n")
            f.write(f"  - Channel: {v['channel']} | Duration: {v['duration_min']:.0f} min | Published: {v['published'][:10]}\n")
        f.write("\n")


if __name__ == '__main__':
    main()

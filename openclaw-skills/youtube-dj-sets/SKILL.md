---
name: youtube-dj-sets
description: "Weekly YouTube DJ set curator. Use as a cron job (every Sunday 20:00) to find and add 5 unwatched electro music DJ sets (>50 min) to the DJ Sets playlist. Covers techno, house, trance, melodic techno, and similar genres. Uses the YouTube Data API v3 to search and manage playlists — no browser required."
---

# YouTube DJ Sets

Automated weekly curation of DJ set videos on YouTube.

## Schedule

Run every Sunday at 20:00 (cron expression: `0 20 * * 0`).

## Environment Variables

The following env vars must be available (set in the `openclaw-env-secret` Kubernetes secret):

- `YOUTUBE_TRANSCRIPT_API_KEY` — SupaData (or equivalent) transcript API key
- `YOUTUBE_CLIENT_ID` — Google OAuth 2.0 Client ID (YouTube Data API v3)
- `YOUTUBE_CLIENT_SECRET` — Google OAuth 2.0 Client Secret

## Workflow

Use the **YouTube Data API v3** for all operations (no browser needed):

1. **Search** — Call `GET https://www.googleapis.com/youtube/v3/search` with:
   - `part=snippet`
   - `type=video`
   - `videoDuration=long` (>20 min; post-filter for >50 min)
   - `q=` set to artist/genre search terms from below
   - `order=relevance` (default) or `order=date` for recent-only queries
   - `maxResults=25`
   - Use **mixed time windows**: some queries with no `publishedAfter` (all time), some with last 7 days, some with last 90 days
2. **Filter by duration** — For each result, call `GET https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=VIDEO_ID` and parse the ISO 8601 duration. Keep only videos ≥50 minutes.
3. **Check playlist** — Call `GET https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&playlistId=PLAYLIST_ID&maxResults=50` to get current playlist video IDs. Skip duplicates.
4. **Get or create playlist** — Search for a playlist named "DJ Sets" via `GET https://www.googleapis.com/youtube/v3/playlists?part=snippet&mine=true`. If not found, create it with `POST https://www.googleapis.com/youtube/v3/playlists`.
5. **Add videos** — For each qualifying video, call `POST https://www.googleapis.com/youtube/v3/playlistItems` with the video ID and playlist ID.
6. **Transcripts (optional)** — If summarising sets, use the Transcript API key to call SupaData for captions.

## Execution

A ready-to-run Python script exists at `~/.openclaw/workspace/youtube_dj_sets.py` (deployed from `skills/youtube-dj-sets/youtube_dj_sets.py`). To execute the weekly workflow:

```bash
python3 ~/.openclaw/workspace/youtube_dj_sets.py
```

This script handles auth, searching, filtering, playlist management, and memory logging. If the script is missing or broken, recreate it following the workflow section below.

## Authentication

Use OAuth 2.0 with the provided Client ID and Client Secret. The refresh token is stored at:

```
~/.openclaw/workspace/.youtube-token.json
```

The script automatically refreshes the access token using the stored refresh token. If the token file is missing or the refresh token has expired (7-day expiry for testing apps), re-authorization is needed — log a note in the daily memory and skip playlist operations.

The API key alone is sufficient for search and public video metadata; OAuth is needed for playlist management.

## Search Strategy

- Pick 3–5 artists randomly from the list each run
- Combine with genre terms: "DJ set", "live set", "mix", "melodic techno set", "afro house set", etc.
- Also search by label names: Afterlife, Cercle, Alter K, Siona Records
- **Use mixed time windows** to get variety across all timeframes:
  - Artist queries: `order=relevance`, **no** `publishedAfter` (captures classic and new)
  - Label queries: `order=date`, `publishedAfter` last 90 days (fresh label content)
  - Genre queries: randomly choose between no filter (all time), last 7 days, or last 90 days
- Shuffle final candidates before selection to avoid always picking the newest
- Diversity: prefer unique channels — avoid adding multiple sets from the same channel

## Artist Reference

Core taste profile (not exclusive — use as seeds for discovery):

- Miss Monique
- Koralova
- NTO
- Teho
- Sultan + Shepard
- Lane 8
- Ben Bohmer
- French 79
- Adriatique
- WhoMadeWho
- Tale of Us
- Anyma
- Argy
- Artbat
- Monolink
- Fideles
- Rufus du Sol
- Elderbrook
- Bob Moses
- Massano
- Mind Against
- Nora Van Elken
- Indira Paganotto
- Tiesto
- Armin van Buuren
- Charlotte de Witte

Labels: Afterlife, Cercle, Alter K, Siona Records

Similar artists and genres are welcome.

## Genre Scope

Techno, house, trance, melodic techno, progressive house, afro house, deep house, organic house, indie dance, and similar electronic genres. New and adjacent genres welcome.

## Duration Filter

Only sets longer than 50 minutes. Typical DJ sets are 1–3 hours. Skip short clips, highlights, or track previews.

## Playlist Target

Add videos to the playlist named **DJ Sets**. Create it if it does not exist.

## Notes

- Prefer high-quality audio/video (official channels, festival recordings, Cercle, Boiler Room, etc.)
- Diversity matters: avoid adding 5 sets from the same artist in one run
- If fewer than 5 qualifying videos are found, add what is available and note it in the daily memory log

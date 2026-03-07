# OpenClaw Skills

Custom skills for OpenClaw AI assistant running on the Pi cluster.

## Directory Structure

```
openclaw-skills/
├── README.md                    # This file
├── youtube-dj-sets/
│   ├── SKILL.md                 # Skill definition
│   ├── cron_jobs.json           # Scheduled execution config
│   └── deploy.sh                # Deployment script
```

## Prerequisites

### YouTube API Credentials

The `youtube-dj-sets` skill requires YouTube API access:

1. **YouTube Transcript API Key**
   - Go to [SupaData](https://www.supadata.ai/) or similar transcript API provider
   - Create an account and generate an API key
   - This key is used by OpenClaw to fetch video transcripts

2. **YouTube Data API v3 (OAuth 2.0)**
   - Go to [Google Cloud Console](https://console.cloud.google.com/)
   - Create a new project or select existing
   - Enable **YouTube Data API v3**
   - Go to **Credentials** → **Create Credentials** → **OAuth client ID**
   - Application type: **Desktop app** (or Web app if using callback)
   - Save the **Client ID** and **Client Secret**

## Configuration

### During Skill Deployment

When running `deploy.sh`, you'll be prompted for YouTube credentials (optional):

```
YouTube Transcript API key: <your-transcript-api-key>
YouTube Data API Client ID: <your-client-id>
YouTube Data API Client Secret: <your-client-secret>
```

These are stored in the `openclaw-env-secret` Kubernetes secret and OpenClaw is automatically restarted to pick up the new credentials.

### Manual Secret Update

To update credentials manually:

```bash
kubectl delete secret openclaw-env-secret -n ai

kubectl create secret generic openclaw-env-secret -n ai \
  --from-literal=OPENROUTER_API_KEY=<your-openrouter-key> \
  --from-literal=YOUTUBE_TRANSCRIPT_API_KEY=<your-transcript-key> \
  --from-literal=YOUTUBE_CLIENT_ID=<your-client-id> \
  --from-literal=YOUTUBE_CLIENT_SECRET=<your-client-secret>

kubectl rollout restart deployment/openclaw -n ai
```

## Deploying Skills

Skills are deployed independently from the main cluster install script.

### Using deploy.sh

Run from the control plane node:

```bash
cd pi-cluster/openclaw-skills
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Prompt for YouTube API credentials (optional)
2. Deploy all skills to the OpenClaw pod
3. Deploy cron jobs
4. Restart OpenClaw if credentials were provided
5. Verify deployment

### Manual Deployment

Copy files directly to the OpenClaw pod:

```bash
# Find the pod
POD=$(kubectl get pods -n ai -l app=openclaw -o jsonpath='{.items[0].metadata.name}')

# Create skills directory
kubectl exec -n ai $POD -- mkdir -p /home/node/.openclaw/skills/youtube-dj-sets

# Copy skill files
kubectl cp openclaw-skills/youtube-dj-sets/SKILL.md ai/$POD:/home/node/.openclaw/skills/youtube-dj-sets/SKILL.md
kubectl cp openclaw-skills/youtube-dj-sets/cron_jobs.json ai/$POD:/home/node/.openclaw/skills/youtube-dj-sets/cron_jobs.json

# Verify
kubectl exec -n ai $POD -- openclaw skills list
```

## Cron Jobs

Skills can have scheduled executions via `cron_jobs.json`:

```json
{
  "jobs": [
    {
      "name": "weekly-youtube-dj-sets",
      "schedule": "0 20 * * 0",
      "timezone": "Europe/Paris",
      "command": "trigger",
      "args": ["youtube-dj-sets"]
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `schedule` | Cron expression (minute hour day month weekday) |
| `timezone` | IANA timezone (e.g., Europe/Paris, UTC) |
| `command` | Action to perform (`trigger` runs the skill) |

### Managing Cron Jobs

```bash
# List cron jobs
kubectl exec -n ai $POD -- openclaw cron list

# Add a cron job
kubectl exec -n ai $POD -- openclaw cron add weekly-dj-sets "0 20 * * 0" "Europe/Paris" youtube-dj-sets
```

## Creating New Skills

1. Create a directory under `openclaw-skills/`:
   ```bash
   mkdir -p openclaw-skills/my-new-skill
   ```

2. Create `SKILL.md` with the skill definition:
   ```markdown
   # My New Skill
   
   Description of what this skill does...
   
   ## Instructions
   
   Step-by-step instructions for OpenClaw...
   ```

3. Optionally add `cron_jobs.json` for scheduled execution

4. Create `deploy.sh` for easy deployment

5. Deploy to cluster:
   ```bash
   cd openclaw-skills/my-new-skill
   ./deploy.sh
   ```

## Current Skills

### youtube-dj-sets

Curates and downloads DJ sets from YouTube channels:
- **Labels:** Afterlife, Cercle, Alter K, Siona Records
- **Schedule:** Sundays at 20:00 (Europe/Paris)
- **Output:** Downloads to configured media directory

## Troubleshooting

### Check skill is loaded
```bash
kubectl exec -n ai $POD -- openclaw skills list
```

### View OpenClaw logs
```bash
kubectl logs -n ai -l app=openclaw --tail=100
```

### Verify environment variables
```bash
kubectl exec -n ai $POD -- env | grep -E "YOUTUBE|OPENROUTER"
```

# Own GPU: Nemotron live + Qwen3 final

English on our own GPU, the experiment behind the dev build's Own GPU
provider. It ran on a rented RTX 4090. Built 2026-10-01.

- **While you talk:** Nemotron Speech Streaming EN 0.6B (cache-aware, 560 ms
  chunks, your names boosted). A new word every ~0.5 s. Drives the overlay and
  the live commands.
- **At key-up:** Qwen3-ASR 1.7B (bf16, vLLM) re-hears the whole take with your
  names as context, English forced, read-back guard. This is the text that pastes.

```
app (Own GPU provider) ── ws://127.0.0.1:8765 ── SSH tunnel ──► pod 127.0.0.1:8765  server.py (Nemotron in-process)
                                                                     └─► 127.0.0.1:8000  qwen-asr-serve (Qwen3, vLLM)
```

Nothing listens on the internet: both servers bind to the pod's 127.0.0.1.

## Use it

1. Tunnel (laptop): `nohup gpu-server/tunnel.sh > /tmp/sayctrl-gpu-tunnel.log 2>&1 &`
   It reconnects by itself. Stop it with `pkill -f tunnel.sh; pkill -f "8765:127.0.0.1:8765"` (the loop first).
2. SayCtrl Dev → Settings → Provider → **Own GPU** → Verify (asks /health).
3. Hold the key and talk. `~/.config/sayctrl-dev/` logs show both models' text per take
   (`Live: Own GPU final by qwen3 — … Nemotron heard: …`).

Without the app: `gpu-server/.venv/bin/python gpu-server/client.py take.wav` or `--mic`.

## Protocol (`/v1/listen`)

client `{"type":"start","sample_rate":16000,"terms":[…]}` → server `{"type":"ready"}` →
client binary PCM16 LE mono 16 kHz → server `{"type":"partial","text":…}` (whole take so far) →
client `{"type":"end"}` → server `{"type":"final","text":…,"live_text":…,"source":"qwen3","timing":{…}}`, then close.
Also `POST /v1/transcribe?terms=a,b` (WAV body → Qwen3 only) and `GET /health`.

## Pod operations

- Restart both servers: `ssh -i <key> -p "$POD_PORT" root@"$POD_HOST" bash /workspace/sayctrl-gpu/start.sh`
- Logs: `/workspace/sayctrl-gpu/logs/{gateway,qwen}.log`
- Deploy a change: `scp -P "$POD_PORT" -i <key> gpu-server/server.py root@"$POD_HOST":/workspace/sayctrl-gpu/` then restart.
- `/workspace` is a network volume (survives stop/start); `/root/nemo-env` is not, so
  `start.sh` restores it from `nemo-env-backup/`. **Terminate** deletes everything.
- A re-created pod gets a new IP/port: set `POD_HOST`/`POD_PORT` for `tunnel.sh`.

## Measurements

Full benchmark against MAI-Transcribe-2 and Soniox (2026-10-02):
`~/.config/sayctrl-dev/bench-experiments/SUMMARY-gpu-system.md`.

- Key-up to final text, on the laptop: 0.43 s median, 0.64 s p90, with one user and a 265 ms ping to Norway.
- The gateway's own share: 109 ms median, 229 ms p90.
- The final no longer waits for Nemotron's last chunk; Nemotron's end of the take follows as `live_final`.

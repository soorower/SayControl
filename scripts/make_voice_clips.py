#!/usr/bin/env python3
"""Makes the agent voice's fixed lines in each of the cloud's voices, for the app to ship.

Every line AgentBridge says word for word ("Okay.", "Sent.", "No agents have
reported yet."…) is rendered once per voice by the voice box (SayCtrl-Cloud's
voice-server, Kokoro) at the cloud's own pace, as the 22.05 kHz 16-bit PCM the
player takes, into Resources/VoiceClips/<voice>/, with manifest.json mapping
each line to its file. CannedClips plays these at once, in the voice picked in
the Agents pane, from the very first time.

The box listens on its localhost only, so reach it through SSH first:

  ssh -i <key> -N -L 18765:127.0.0.1:18765 root@<voice box> &
  VOICE_SECRET=<the voice box's secret> python3 scripts/make_voice_clips.py

Re-run it whenever a line is added or reworded in AgentBridge, or a voice
or the pace changes (keep SPEED with KOKORO_SPEED in SayCtrl-Cloud's agent.ts).
"""
import json, os, re, sys, urllib.request

URL = os.environ.get("VOICE_URL", "http://127.0.0.1:18765/speak")
SECRET = os.environ["VOICE_SECRET"]
VOICES = ["af_heart", "am_puck"]  # VoiceIO.relayVoices
SPEED = 1.15                       # the Worker's KOKORO_SPEED, with no speed of the app's own
LINES = [
    # CannedClips.phrases
    "Sent.", "Okay.", "Goodbye.", "Allowed.", "Denied.",
    "Anything else?", "Go ahead.", "Okay, cancelled.", "Dropped.",
    # AgentBridge's other fixed lines
    "That session has ended — it can't take messages any more.",
    "That one can't be undone, so it's yours to approve on the screen.",
    "Started. It'll report here when it has something.",
    "Opened in the Claude app — confirm the folder there and I'll send your brief in.",
    "No agents have reported yet.",
    "No agents I can reach quietly right now.",
    "I don't know any project folders yet — talk to an agent once, then try again.",
    "I couldn't open the terminal.",
    "I couldn't find that folder.",
    # The samples (AgentBridge.sampleNews and playQuestionSample), as spoken:
    # "SayControl" is said "Say Control", and a question reads out its options.
    "Your agent on Say Control finished.",
    "I fixed the login bug. The page loads in under a second now, and all the tests pass. Want me to open the changes?",
    "I added a dark mode to the settings page. It follows your Mac's appearance. Should I push it?",
    "Your agent on Say Control asks. Question 1 of 2. Which color should the new button be? Options: 1, Blue. 2, Green. 3, Orange. Or say something else.",
    "Question 2 of 2. Should I add tests for it? Options: 1, Yes, add tests. 2, No, skip them. Or say something else.",
]

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "VoiceClips")
manifest = {"model": "kokoro-82m", "speed": SPEED, "voices": {}}
for voice in VOICES:
    os.makedirs(os.path.join(out, voice), exist_ok=True)
    manifest["voices"][voice] = {}
    for line in LINES:
        req = urllib.request.Request(URL, json.dumps({"text": line, "voice": voice, "speed": SPEED}).encode(),
                                     {"Content-Type": "application/json", "X-Voice-Secret": SECRET})
        pcm = urllib.request.urlopen(req, timeout=30).read()
        if len(pcm) < 4410 * 2:
            sys.exit(f"{voice}: {line!r} came back too short ({len(pcm)} bytes)")
        name = re.sub(r"[^a-z0-9]+", "-", line.lower()).strip("-")[:48] + ".pcm"
        with open(os.path.join(out, voice, name), "wb") as f:
            f.write(pcm)
        manifest["voices"][voice][line] = f"{voice}/{name}"
        print(f"{voice}  {len(pcm) / 44100:4.1f} s  {line}")
with open(os.path.join(out, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=1, ensure_ascii=False)
    f.write("\n")

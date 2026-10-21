# Release testing

What to try by hand before a DMG goes out, on a Mac that is not the one it was
built on. Each pass is the same list; the three Macs are what differ. Tick
them in the release's notes, and anything that fails is a release blocker
until it is understood.

The build itself already proves a few things, so they are not on the list:
every API the app uses exists on macOS 13 (the compiler targets it), the
Intel slice transcribes and draws the UI (it is run under Rosetta at release
time: `arch -x86_64 SayCtrl --transcribe clip.wav` and
`--onboardingshot`), and the hardened signature carries the two entitlements.

## The three Macs

1. **A fresh user on this Mac.** System Settings → Users & Groups → Add
   Account → Standard. Log in as them. Nothing of yours is there: no config,
   no models, no grants — the closest thing to a stranger's Mac without
   leaving the room. Delete the account afterwards.
2. **An Intel Mac.** Borrow one. The x86_64 slice has no Metal, so local
   models run on the CPU: slower, and the thing to feel is whether Parakeet
   is still usable for a sentence.
3. **macOS 13 Ventura.** The oldest version the DMG claims to support. A VM
   (UTM, VirtualBuddy) is fine; the permission prompts are the point, and
   they work in a VM.

## The pass

Install
- [ ] Download the DMG from sayctrl.com (not from this repo): the version and
      size beside the button match `latest.json`.
- [ ] Open the DMG, drag to Applications, open the app. **No Gatekeeper
      warning of any kind.** If macOS says it cannot check for malware, the
      notarisation did not take — stop here.
- [ ] The first run opens on its own: the pill appears over the desktop,
      hears "Welcome to SayControl" with a note per word, and opens into the
      window on the chord. With accounts off the left side says "Welcome"
      and "Get started"; with them on, "Continue with Google".

First run
- [ ] Signed in, it says "Welcome, <name>." and moves on to the switches by
      itself — no step numbers, no Continue.
- [ ] Switches: Microphone, Accessibility, Input Monitoring and the Globe
      key each show Apple's prompt or pane when the row's button is
      pressed, and tick green with a note when the grant lands. Nothing is
      pre-ticked on a fresh user. With no account and no model, a Voice row
      downloads the starter model with a progress line.
- [ ] Each grant moves the list on as soon as macOS reports it, with no
      wait: back from System Settings, the tick is already there.
- [ ] Input Monitoring: after macOS's Quit & Reopen the window comes back
      on the switches with a pop, not at the start.
- [ ] With Microphone and Accessibility on, "Skip for now →" shows in the
      bottom-right corner and opens the app; with all four on, the app
      opens by itself.
- [ ] Opening: the window grows into the main one, the pages arrive, and
      the pill says "Hold fn to talk" once. Settings › General shows Launch
      at login on; log out and in — the menu-bar icon is there.
- [ ] The Ready card in the sidebar says "fn may miss in some apps" when
      Input Monitoring was skipped.

Dictation
- [ ] Hold fn in TextEdit, Mail, Safari's address bar, Slack (if installed)
      and a terminal: the words land in each. In the terminal, "list the
      files" arrives as `ls` and does not run until Return.
- [ ] "Scratch that" takes the paste back. "Send it" presses Return.
- [ ] "Take a screenshot" mid-sentence pastes a picture.
- [ ] Fix a misheard word right after the paste; say it again; it comes out
      right.
- [ ] Turn Wi-Fi off. Dictation still works (local model).

Settings
- [ ] Every section opens. There is no Account or Billing in the rail.
- [ ] Model → SayCtrl tab explains cloud minutes are coming and has no
      button that leads nowhere; Local tab lists the downloaded model and
      can download another one (progress, checksum, Use).
- [ ] Cohere Transcribe is the first row. Download it (1.5 GB), press Use,
      dictate a sentence: it lands, and in your language. Turn Live
      streaming on: words appear while you talk and the ones already shown
      don't jump about. A Whisper row dims to "no live"; say "use the local
      model" and the biggest download wins, which may be this one.
- [ ] Dictation → "Read the screen for names" says what it sends and when.
- [ ] Help → "Report a problem" opens a Mail draft to support@saycontrol.com
      with a .txt attached; the attachment has versions and log lines and
      **no dictation text**. "Getting started" opens sayctrl.com/install.
- [ ] About: version and build number, link to sayctrl.com, no mention of a
      key or a repo.

Updates
- [ ] Menu bar → "Check for Updates…" says the app is up to date (against
      the live appcast) or offers the newer one, and installing it works and
      keeps the Accessibility grant (Developer ID signature, same Team ID).

Uninstall
- [ ] Quit, drag to the Trash, empty it. Nothing else is running (`pgrep
      SayCtrl` is empty), and `~/.config/sayctrl` is the only thing left,
      by design.

## After the pass

Note the macOS version, the Mac, and the date in the release's notes. A
failure on one of the three Macs that cannot be reproduced on the others is
still a failure — that is the Mac the next user has.

## Agent voice (dev only for now)

What it is: Claude Code's `Stop`, `Notification` and `PermissionRequest`
hooks post to `http://127.0.0.1:47712/sayctrl/<event>` (47711 in the
shipping build). Codex needs NOTHING installed: it writes every session to
`~/.codex/sessions/<date>/rollout-*.jsonl` as it works, and SayCtrl tails
those files — `task_complete` carries `last_agent_message`, which is the
Stop hook's payload by another name. Codex hooks are optional, and buy one
thing only: a permission request, which has to be answered while the agent
waits. They reach the same port on `/sayctrl/codex/<event>` — same events,
same field names — as a one-line `curl` that pipes the event in and prints
SayCtrl's answer back out, since Codex has no http hook handler. SayCtrl speaks a one-line summary through Inworld when `INWORLD_API_KEY` is in .env
(tts-2-flash, voice Shaun; `AGENT_INWORLD_VOICE` / `AGENT_TTS_MODEL` change
them — any `inworld-…` model routes here), otherwise ElevenLabs (the
expressive v3 model, voice Brian; `AGENT_VOICE_ID` picks the voice); the
Mac voice if every key is missing;
Polish key → Cerebras for the words), shows it on a chat card bottom-right
(`SayCtrl` on the left, you on the right, the session in the header),
listens once the voice has finished, and carries the reply back. "SayCtrl"
is said "Say Control". Everything is in
`sayctrl.log` under `Agent voice:`. Never test with `claude -p` — it bills
API money; post JSON to the port with curl, or use a real session.

Setup: one switch. Main window → sidebar → **Agents → Claude** (it lived
in Settings → System through 2.2; a pointer there still leads here) →
"Speak when an agent finishes". That is the whole of it — there is no
Install button anywhere any more. Switching it ON writes Claude Code's
hooks into `~/.claude/settings.json` for you (backup at
`settings.json.sayctrl-bak`, other people's hooks untouched; they load
when a Claude session starts), and switching it OFF takes them back out
along with the `crossSessionInbound` grant, so nothing of ours is left in
another app's config. Codex needs nothing written at all — see 17. Both
pages list **Recent sessions** — every session the voice heard from in the
last day, that agent's own; "Continue by voice" opens a reply episode for
that session exactly like "any agent updates?". The sidebar shows ONE
Agents row — a hub page with the conversation tallies, the live sessions
("Running now"), and a tile per agent; the per-agent pages open from the
tiles (an "All agents" button leads back), and the Agents row stays lit
while one is open. Cursor and OpenCode tiles say "Coming soon"; their
pages are still placeholders that link back to the two that work.

1. **Voice alone.** **Play a sample** → the card, the voice, the sentences
   landing as they are spoken, then the mic open ~7 s. Silence → the log
   says `episode over — nothing said` and the card fades.
2. **Replying hands-free.** Once the voice finishes, the card says
   Listening… and the NORMAL dictation starts by itself — the pill
   appears, the user's own provider transcribes, and the reply shows in
   the Overview with its clip like any dictation (log: `heard (mic)`).
   The ear's VAD only times it: talking starts the clock, two seconds
   of quiet stops the take. Then "Anything else?" — say "no" (or
   nothing) → the reply is cleaned by the LLM ("tell Claude that…"
   stripped) and sent; say more → it is added and asked again.
   If the card sits on Listening… while you talk, the log tells which
   half failed: no `ear — voice (… vad …)` line means the VAD never
   heard you (the dev build keeps the first three refused windows as
   `recordings/ear-reject-<epoch>.wav` — play one back); a `voice` line
   with no `heard (mic)` means the dictation side lost it (its normal
   logs apply, and the take is in the Overview to replay).
3. **Cut in by key.** Press the dictation key while it talks; dictate;
   release. Same flow, `cut in by key` in the log. Nothing is pasted
   where you were.
4. **Dictation still works after.** The bug of 2026-08-24: after any
   episode, dictate normally — it must transcribe. If `Empty transcript`
   follows an episode, that is the regression.
5. **Real finish.** In a terminal or the Claude desktop app, any short
   prompt. Expect `finished from <folder>` then the summary.
6. **Reply lands.** After a real finish, say "now run the tests", then
   "no" to "Anything else?". The Claude app (or the terminal named by
   TERM_PROGRAM) comes forward, the words are pasted and sent, the
   previous app comes back. If the prompt box wasn't focused, the words
   are on the clipboard — the known desktop-app gap.
7. **Permission by voice.** Trigger a prompt (a `rm` in a fresh folder).
   "…wants to run …. Allow?" — "yes" runs it without the dialog, "no"
   denies with "Denied by voice through SayCtrl", silence (~7 s) shows
   the normal dialog. The hook waits at most 120 s.
8. **Questions by voice.** **Play a question**, or have Claude ask a
   multiple-choice question. Each question is read with numbered
   options; answer "the second one", "two", the option's own words, or
   anything else (sent as a custom answer). With a real session the
   dialog is skipped and Claude continues with your answers.
9. **Two at once.** Finish two sessions within seconds: the second waits
   for the first episode; a permission that waited over 30 s is handed
   back to the screen instead of asked late.
10. **Open mic off.** Switch off "Listen without a key press": no mic,
    the key still answers for 25 s.
11. **Stopping it.** At any point say "that's all", "goodbye", "stop",
    "enough", "that's all for now" — the episode ends (words already
    given are sent first). The × on the card ends it silently. "Anything
    else?" is asked at most once per reply.
12. **Coming back to a session.** Dictate "any agent updates?" — also
    "is there any agent running?", "any recent agent messages?", and the
    trailing-off forms ("…or something like that?") — each
    recent session lands as its own rounded card, popping onto the stack
    one after another (number badge · name · id · when · last line, with
    the owner's mark top right: Claude's starburst or the OpenAI blossom),
    and the voice asks "Which one?". The list survives a relaunch
    (`agent-recents.json`, one day's worth) — quit and reopen the app,
    ask again, and the same sessions must come back; say a number or the folder name, then
    what to tell it. A rough name ("the say control one", "that whisper
    thing") should still pick right: the literal match runs first, then
    the Polish LLM reads the pick (log: `pick: LLM matched … → #n`) —
    without a Polish key only literal matching runs. Or menu bar → Agents → pick one. The reply goes into that
    session even though it is NOT the front window — via its inbox socket
    (log: "delivered through the session's inbox socket"). Confirm the
    other Claude session actually receives the message. Fallback order:
    socket → tmux → iTerm → focus-and-paste → clipboard. NOTE the socket
    needs the session started AFTER the hooks were installed (so the two
    X-Messaging headers are forwarded).
13. **Replies into a prompts-off session.** A session running with
    permission prompts off HOLDS a socket message ("Held peer message"
    banner, nothing reaches Claude) unless the receiver accepts local
    senders. Switch on **Deliver replies without review** in the Agent
    voice card → `crossSessionInbound: "accept"` appears in
    `~/.claude/settings.json` and the same spoken reply now lands
    directly. Switch it off (or switch the agent voice off) → the key is
    gone from the file. A `hold`/`refuse` value the user set by hand
    must survive the switch-off untouched.
14. **Screenshot in a reply.** After a finish, answer with "take a
    screenshot" (alone, or inside a sentence — "the padding is off,
    take a screenshot"). The card and pill dip out of the picture, the
    HUD says "Screenshot attached to the reply", and the message that
    lands in the session carries "(screenshot of my screen:
    /tmp/…/SayCtrlShots/sayctrl-shot-….png — open it)" — the agent can
    open the file. The command words themselves must NOT appear in the
    delivered text. A MENTION mid-sentence ("I just said take a
    screenshot, did you get it?") keeps the sentence as spoken — but if
    the live stream captured a shot while you said it (HUD: "Screenshot
    taken"), that shot still rides along; a watched capture must never
    vanish. A screenshot spoken into a permission or a multiple-choice
    answer is ignored (those go back as JSON). Without Screen Recording
    granted, the words pass through unchanged and the HUD asks for the
    permission.
15. **Starting a session by voice.** Dictate "create a new claude session
    on <folder>" (also "start/open/make a new session/agent/project
    in/for …"; any mishearing of Claude — "cloud", "plot" — is fine, the
    word between "new" and "session" isn't matched by spelling; opener
    words — "Okay, start a new…" — are let through, mid-sentence forms
    still are not). Say "codex" there instead and a CODEX session is
    what starts — its mishearings ("codecs", "kodak code") count too,
    and the confirm line says which agent it is about to start. Works
    BOTH as a fresh dictation and spoken mid-conversation with an agent —
    the episode hands over (log: "reply is a new-session command"); not
    during a permission or a question. The folder is matched against
    everywhere the agents have run, the workspaces up to two levels above
    them (never the home folder), plus the folders beside each —
    letter-for-letter first, the LLM for rough names. Then the walk: "What
    should it work on?" → speak the brief → "Starting Claude in <folder> —
    go?" → "yes" starts it; anything but yes cancels, as does
    "cancel"/"stop" at any step. WHERE it opens follows your habit: last
    session with no terminal forwarded → the Claude desktop app (via its
    documented `claude://code/new?folder=…` deep link — the app asks once
    to confirm the linked folder; that consent is Claude's own, not
    skippable, and a SECOND session in the same folder won't ask). The
    brief does NOT ride the link: when the fresh session boots, its
    SessionStart hook hands SayCtrl the session's socket and the brief
    goes in as a real sent message (HUD: "Brief sent to the new session";
    log: "brief delivered through the fresh session's socket"; fresh
    starts only, 3-minute window). The hook set is written and refreshed
    at app launch (log: "Claude hooks in place for port …"). Otherwise
    a terminal window (iTerm if that's where sessions run, else Terminal)
    running `claude "<brief>"`. Saying "…in the desktop app" or "…in the
    terminal" overrides the habit, and the confirm line names the
    destination. Mid-prose mentions ("…create a new session token…") must
    NOT trip it. First terminal run may show the macOS automation consent
    — allow it.
16. **The ear in a noisy room.** Onset and end-of-speech are decided by
    the streaming Silero VAD (fed every frame, state carried, on a
    120 Hz high-passed feed so desk rumble doesn't drown it): a fan must
    not open the ear, and a 2 s pause must close it. The log's `ear —
    loud (… vad 0.87) → voice` shows the live probability. If `heard:`
    never appears after "Listening…", note the room (fan, music,
    distance) in the report.
14. **Read a session back.** After "Which one?", say "read the last
    message" (or "what did it say") — the voice reads the remembered
    message whole and asks "Anything to send back?". An answer nobody
    understands re-prompts once ("Say a number, a name, or…") instead
    of silently ending.
15. **Name a session.** During any episode say "call it the billing
    fix" — "Okay — Billing fix.", and from then on the voice opens
    with that name ("Billing fix finished. …"), the card list and the
    menu show it, and "talk to the billing fix" picks it. Survives a
    relaunch (agent-names.json in the config folder).
16. **Digest.** Finish two sessions while a third episode is playing
    (or while away): one spoken rundown — "2 agents finished. A: … B:
    …" — then "Which one?", instead of two back-to-back episodes.
    Permission prompts and questions never digest; they stay their own
    episodes.

17. **Codex sessions — nothing installed, nothing to trust.** Just talk
    to Codex: a short prompt in any session (desktop app or terminal) →
    `codex turn finished [<id>] on <folder>` in the log, then the summary,
    exactly like Claude. The status line reads "On. Reading along with
    your Codex sessions." Codex writes each session to
    `~/.codex/sessions/<date>/rollout-*.jsonl` as it works and SayCtrl
    tails it: `task_complete` carries `last_agent_message`, `user_message`
    carries what was asked. Only real sessions are announced — a scheduled
    **automation** finishing (`thread_source: "automation"`, and on a Mac
    that runs them they are most of the traffic) must stay silent, as must
    Codex's own realtime voice mode. Restarting SayCtrl must NOT replay the
    day's finished turns; it reads from the end of every existing file.
    Reply by voice and it goes in through `codex queue --thread` with no
    window brought forward (log: "delivered through the codex queue"); a
    thread its daemon has lost falls back to tmux → iTerm →
    focus-and-paste. "Show me" on a desktop-app session opens
    `codex://threads/<id>`, landing on that thread rather than merely
    raising the app. Card headers show the thread's own name from
    `~/.codex/session_index.jsonl`; "what did it change?" reads the
    rollout. There is no SessionEnd without hooks, so a Codex row stays
    listed until it ages out after a day. Both agents' sessions share one
    list — "any agent updates?" and the menu bar name each row by its
    agent — and one broadcast reaches both ("tell all agents to…").
    To test against a session you don't want in your real history, launch
    the app with `CODEX_HOME=<scratch> "SayCtrl Dev.app/Contents/MacOS/SayCtrl"`
    and run codex with the same `CODEX_HOME`.
18. **Nothing left behind.** An older build installed Codex hooks in
    `~/.codex/hooks.json`; this one takes them out at launch (log:
    "removed the old Codex hooks — none are needed now") and leaves any
    other hooks in that file exactly as they were — a file that was only
    ours is deleted, a file holding anything else is kept. Run once, the
    line never appears again. Then switch the agent voice off: Claude's
    hooks leave `~/.claude/settings.json` too. Nothing SayCtrl wrote into
    another app's config outlives the switch.
    Verified 2026-08-24 against codex-cli 0.149.0-alpha: a real turn
    reaches the voice through the rollout alone, and the queue reaches the
    app-server daemon.
19. **Rate limits, and everything else that stops an agent dead.** The
    quietest failure there is: the turn never finishes, so on Claude no
    Stop hook fires, and the window just sits there with a red line until
    somebody looks. Both agents are watched for it — Codex through the
    `error` beside a null `last_agent_message` in `task_complete`, Claude
    through `isApiErrorMessage` entries in its transcript — and the voice
    says "<name> hit a rate limit and stopped", then takes a reply for
    that session like any other episode (say "carry on when you can" and
    it goes in; the user's own screenshot of this had them typing "finish
    it" by hand). Also covered, in these words: usage limit reached
    (with "it comes back at <time>" when Claude names the reset), ran out
    of credits (402 / low credit balance), needs you to sign in again
    (401 / expired OAuth), and on Codex a spent budget or a full context
    window. What must stay SILENT: "API Error: Connection closed
    mid-response" and its "Connection lost" twin — transient, and Claude
    recovers on its own — and any ordinary message that merely talks
    about rate limits. One stall is spoken once per session per reason
    per 15 minutes, so an agent retrying in a loop doesn't nag. To test
    without waiting to be limited, write a transcript ending in an
    `isApiErrorMessage` line into a scratch folder under
    `~/.claude/projects/`, or a rollout ending in a `task_complete` with
    an `error` under `~/.codex/sessions/<date>/` — both were verified
    that way on 2026-08-25 with the exact 429 payloads these two write.

Known gaps: iTerm (`ITERM_SESSION_ID`) and tmux (`TMUX_PANE`) routes type
into the exact session without moving focus but are untested; VS Code's
terminal and the desktop app need focus-and-paste; which session inside
the desktop app receives the paste is whatever is focused. On the Codex
side, whether a queued message wakes an IDLE desktop-app thread (rather
than waiting for its next turn) is unconfirmed, and a permission request
cannot be answered by voice at all — that is the one thing the rollout
file can't carry, and the hooks that could carry it cost more setup than
the feature is worth.

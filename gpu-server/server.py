"""SayCtrl GPU dictation gateway: Nemotron live, Qwen3 final.

One WebSocket per dictation (hold key -> release):

  client -> {"type": "start", "sample_rate": 16000, "terms": ["Soniox", ...]}
  server -> {"type": "ready"}
  client -> binary frames, PCM16 little-endian mono 16 kHz, any size
  server -> {"type": "partial", "text": "..."}          (Nemotron, every 560 ms chunk)
  client -> {"type": "end"}                              (key-up)
  server -> {"type": "final", "text": "...", "live_text": "...", "source": "qwen3", "timing": {...}}
  server -> {"type": "live_final", "text": "..."}       (Nemotron's own end of the take, for comparison)
  server closes the socket. {"type": "ping"} at any time is answered with {"type": "pong"}.

Also: POST /v1/transcribe (body = WAV file, ?terms=a,b,c) -> Qwen3 only; GET /health.

Nemotron Speech Streaming EN 0.6B runs here, in-process, cache-aware (the
same chunk loop as NeMo's speech_to_text_cache_aware_streaming_infer.py, fed
from a growing buffer instead of a file). Qwen3-ASR 1.7B runs in a separate
vLLM server (qwen-asr-serve on 127.0.0.1:8000); at key-up the whole take goes
there with the user's terms as the system turn. Binds to 127.0.0.1 only: reach
it through an SSH tunnel.
"""
import asyncio, base64, copy, hashlib, io, json, logging, os, re, tempfile, threading, time

import aiohttp
import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

SR = 16000
QWEN_URL = os.environ.get('QWEN_URL', 'http://127.0.0.1:8000/v1/chat/completions')
QWEN_MODEL = os.environ.get('QWEN_MODEL', 'Qwen/Qwen3-ASR-1.7B')
NEMO_MODEL = os.environ.get('NEMO_MODEL', 'nvidia/nemotron-speech-streaming-en-0.6b')
# [70, 6] = 560 ms chunks (the bench's most accurate); [70, 1] = 160 ms.
LOOKAHEAD = int(os.environ.get('NEMO_LOOKAHEAD', '6'))
BOOST_ALPHA = float(os.environ.get('NEMO_BOOST_ALPHA', '1.0'))
QWEN_TERMS = int(os.environ.get('QWEN_TERMS', '100'))   # the app itself sends at most 50

log = logging.getLogger('gateway')
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

# --------------------------------------------------------------------------- Nemotron

class Nemotron:
    """The model plus one lock: every GPU call goes through `run`, one at a time."""

    def __init__(self):
        import nemo.collections.asr as nemo_asr
        from nemo.collections.asr.parts.utils.streaming_utils import CacheAwareStreamingAudioBuffer
        m = nemo_asr.models.ASRModel.from_pretrained(NEMO_MODEL)
        m.encoder.set_default_att_context_size([70, LOOKAHEAD])
        m.encoder.setup_streaming_params()
        self.model = m.cuda().eval()
        buf = CacheAwareStreamingAudioBuffer(model=self.model)   # borrowed for its dither-free preprocessor
        self.pre = buf.preprocessor.cuda().eval()
        self.cfg = self.model.encoder.streaming_cfg
        sf_ = self.model.encoder.pre_encode.get_sampling_frames() if hasattr(self.model.encoder.pre_encode, 'get_sampling_frames') else None
        self.sampling_frames = sf_
        self.lock = threading.Lock()
        self.boost_key = None
        self.base_decoding = copy.deepcopy(self.model.cfg.decoding)
        log.info('nemotron ready: %s', self.cfg)

    def set_terms(self, terms):
        """Phrase boosting is a model-wide decoding setting; switch it when a take's list differs."""
        key = hashlib.md5('\n'.join(terms).encode()).hexdigest() if terms else None
        if key == self.boost_key:
            return
        from omegaconf import OmegaConf, open_dict
        dec = copy.deepcopy(self.base_decoding)
        with open_dict(dec):
            dec.strategy = 'greedy_batch'
            dec.fused_batch_size = -1
            if terms:
                path = os.path.join(tempfile.gettempdir(), f'nemo-terms-{key}.txt')
                with open(path, 'w') as f:
                    f.write('\n'.join(terms) + '\n')
                dec.greedy.boosting_tree = OmegaConf.create({'key_phrases_file': path})
                dec.greedy.boosting_tree_alpha = BOOST_ALPHA
        t0 = time.time()
        self.model.change_decoding_strategy(dec, verbose=False)
        self.boost_key = key
        log.info('boosting %d terms (%.0f ms)', len(terms), (time.time() - t0) * 1000)

    def features(self, audio):
        x = torch.from_numpy(audio).cuda()[None]
        n = torch.tensor([len(audio)], device='cuda')
        feats, flen = self.pre(input_signal=x, length=n)
        return feats, int(flen[0])


class LiveStream:
    """One dictation's cache-aware state. `feed` runs chunks as audio arrives; `flush` runs the tail."""

    def __init__(self, nemo: Nemotron, terms):
        self.nemo = nemo
        self.terms = terms
        self.audio = np.zeros(0, np.float32)
        self.idx = 0            # next feature frame to decode
        self.step = 0
        self.cache = None
        self.hyps = None
        self.pred = None
        self.text = ''

    def _chunk_size(self, cfg_val):
        if isinstance(cfg_val, list):
            return cfg_val[0] if self.idx == 0 else cfg_val[1]
        return cfg_val

    def _run(self, feats, total, last):
        """Decode every whole chunk available in feats[:, :, :total]; with `last`, also the tail."""
        n = self.nemo
        cfg = n.cfg
        m = n.model
        if self.cache is None:
            self.cache = m.encoder.get_initial_cache_state(batch_size=1)
        while self.idx < total:
            chunk = self._chunk_size(cfg.chunk_size)
            shift = self._chunk_size(cfg.shift_size)
            if not last and self.idx + chunk > total:
                break
            piece = feats[:, :, self.idx:min(self.idx + chunk, total)]
            sfr = n.sampling_frames
            if sfr is not None:
                need = (sfr[0] if self.idx == 0 else sfr[1]) if isinstance(sfr, list) else sfr
                if piece.size(-1) < need:
                    break
            pre = self._chunk_size(cfg.pre_encode_cache_size)
            if self.idx == 0:
                cache_pre = feats.new_zeros((1, feats.size(1), pre))
            else:
                cache_pre = feats[:, :, max(0, self.idx - pre):self.idx]
                if cache_pre.size(-1) < pre:
                    cache_pre = torch.cat([feats.new_zeros((1, feats.size(1), pre - cache_pre.size(-1))), cache_pre], -1)
            x = torch.cat([cache_pre, piece], -1)
            xlen = torch.tensor([x.size(-1)], device=x.device)
            final_step = last and self.idx + shift >= total
            c0, c1, c2 = self.cache
            (self.pred, texts, c0, c1, c2, self.hyps) = m.conformer_stream_step(
                processed_signal=x, processed_signal_length=xlen,
                cache_last_channel=c0, cache_last_time=c1, cache_last_channel_len=c2,
                keep_all_outputs=final_step, previous_hypotheses=self.hyps, previous_pred_out=self.pred,
                drop_extra_pre_encoded=0 if self.step == 0 else cfg.drop_extra_pre_encoded,
                return_transcription=True)
            self.cache = (c0, c1, c2)
            self.idx += shift
            self.step += 1
            h = texts[0]
            self.text = (h.text if hasattr(h, 'text') else str(h)).strip()

    def feed(self, pcm: np.ndarray):
        """Append audio; decode the chunks whose features can no longer change. Returns text if it changed."""
        self.audio = np.concatenate([self.audio, pcm])
        before = self.text
        with self.nemo.lock, torch.inference_mode():
            self.nemo.set_terms(self.terms)
            # A frame is final once its 512-sample window is fully inside the audio heard.
            stable = (len(self.audio) - 256) // 160 + 1 - 1
            chunk = self._chunk_size(self.nemo.cfg.chunk_size)
            if stable < self.idx + chunk:
                return None
            feats, _ = self.nemo.features(self.audio)
            self._run(feats, min(stable, feats.size(-1)), last=False)
        return self.text if self.text != before else None

    def flush(self):
        with self.nemo.lock, torch.inference_mode():
            self.nemo.set_terms(self.terms)
            if len(self.audio) >= 1600:
                feats, flen = self.nemo.features(self.audio)
                self._run(feats, flen, last=True)
        return self.text

# --------------------------------------------------------------------------- Qwen3

def echoes(text, context):
    """Port of the app's LocalEngine.echoes: Qwen3 read the term list back on a near-silent clip."""
    if ',' not in text:
        return False
    lower = text.lower(); pos = 0; in_order = 0
    for term in context.lower().split(', '):
        if not term:
            continue
        hit = lower.find(term, pos)
        if hit < 0:
            continue
        in_order += 1; pos = hit + len(term)
    return in_order >= 5


def repeats_prose(text, prose, run=8):
    """Port of the app's LocalEngine.repeatsProse: the text before the caret written back out."""
    w = lambda s: re.findall(r"[a-z0-9']+", s.lower())
    t, p = w(text), w(prose)
    if len(t) < run or len(p) < run: return False
    grams = {' '.join(p[i:i + run]) for i in range(len(p) - run + 1)}
    return any(' '.join(t[i:i + run]) in grams for i in range(len(t) - run + 1))


async def qwen3(session, audio, terms, context_text=''):
    names = ', '.join(terms[:QWEN_TERMS])
    context = names + ('\n\n' + context_text if context_text else '')
    buf = io.BytesIO(); sf.write(buf, audio, SR, format='WAV', subtype='PCM_16')
    wav = base64.b64encode(buf.getvalue()).decode()
    dur = len(audio) / SR

    async def decode(ctx):
        body = {'model': QWEN_MODEL, 'temperature': 0.0, 'max_tokens': 32 + int(dur * 6),
                'messages': [{'role': 'system', 'content': ctx},
                             {'role': 'user', 'content': [{'type': 'input_audio', 'input_audio': {'data': wav, 'format': 'wav'}}]}]}
        # English is forced by the server's chat template (qwen_en.jinja), as the app does.
        async with session.post(QWEN_URL, json=body) as r:
            j = await r.json()
        if 'choices' not in j:
            raise RuntimeError(str(j)[:300])
        return j['choices'][0]['message']['content'].split('<asr_text>')[-1].strip()

    text = await decode(context)
    if context and echoes(text, context):
        log.info('qwen3 read the list back; decoding again without it')
        text = await decode('')
    elif context_text and repeats_prose(text, context_text):
        log.info('qwen3 wrote the earlier text back; decoding again with the names alone')
        text = await decode(names)
    return text

# --------------------------------------------------------------------------- app

app = FastAPI()
NEMO: Nemotron = None
HTTP: aiohttp.ClientSession = None


@app.on_event('startup')
async def startup():
    global NEMO, HTTP
    NEMO = await asyncio.to_thread(Nemotron)
    HTTP = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=60))
    # Warm both models so the first dictation is not slow.
    s = LiveStream(NEMO, [])
    await asyncio.to_thread(s.feed, np.zeros(SR * 2, np.float32))
    await asyncio.to_thread(s.flush)
    try:
        await qwen3(HTTP, np.zeros(SR, np.float32), [])
        log.info('qwen3 warm')
    except Exception as e:
        log.warning('qwen3 not reachable yet: %s', e)


@app.get('/health')
async def health():
    ok = True
    try:
        async with HTTP.get(QWEN_URL.replace('/chat/completions', '/models')) as r:
            ok = r.status == 200
    except Exception:
        ok = False
    return {'nemotron': NEMO is not None, 'qwen3': ok, 'lookahead_ms': 80 * (LOOKAHEAD + 1)}


@app.post('/v1/transcribe')
async def transcribe(request: Request):
    body = await request.body()
    audio, sr = sf.read(io.BytesIO(body), dtype='float32')
    if audio.ndim > 1:
        audio = audio.mean(1)
    if sr != SR:
        return JSONResponse({'error': f'need {SR} Hz audio, got {sr}'}, 400)
    terms = [t.strip() for t in request.query_params.get('terms', '').split(',') if t.strip()]
    t0 = time.time()
    text = await qwen3(HTTP, audio, terms)
    return {'text': text, 'ms': round((time.time() - t0) * 1000)}


@app.websocket('/v1/listen')
async def listen(ws: WebSocket):
    await ws.accept()
    stream = None
    terms = []
    context_text = ''
    pending = []           # PCM not yet given to Nemotron
    heard = []             # every frame, in order: what Qwen3 hears at key-up
    busy = asyncio.Event(); busy.set()   # set = Nemotron idle for this stream
    t_start = time.time()
    try:
        while True:
            msg = await ws.receive()
            if msg['type'] == 'websocket.disconnect':
                return
            if msg.get('bytes') is not None:
                if stream is None:
                    stream = LiveStream(NEMO, terms)
                pcm = np.frombuffer(msg['bytes'], '<i2').astype(np.float32) / 32768.0
                heard.append(pcm); pending.append(pcm)
                if busy.is_set():
                    pcm = np.concatenate(pending); pending.clear(); busy.clear()

                    async def step(pcm=pcm):
                        try:
                            text = await asyncio.to_thread(stream.feed, pcm)
                            if text is not None:
                                await ws.send_text(json.dumps({'type': 'partial', 'text': text}))
                        except Exception as e:
                            log.exception('live step failed: %s', e)
                        finally:
                            busy.set()
                    asyncio.create_task(step())
                continue
            data = json.loads(msg.get('text') or '{}')
            kind = data.get('type')
            if kind == 'ping':   # answered from the receive loop: shows how late it reads
                await ws.send_text(json.dumps({'type': 'pong', 'id': data.get('id')}))
            elif kind == 'start':
                if int(data.get('sample_rate', SR)) != SR:
                    await ws.send_text(json.dumps({'type': 'error', 'message': f'sample_rate must be {SR}'}))
                    await ws.close(); return
                terms = [str(t).strip() for t in data.get('terms') or [] if str(t).strip()][:200]
                context_text = str(data.get('context_text') or '')[-2000:]
                stream = LiveStream(NEMO, terms)
                await ws.send_text(json.dumps({'type': 'ready'}))
            elif kind == 'end':
                # Qwen3 starts at once on everything heard. The final goes out the
                # moment it answers: Nemotron's last chunk is not waited for — the
                # app pastes Qwen3's text — and follows as `live_final`.
                t_end = time.time()
                audio = np.concatenate(heard) if heard else np.zeros(0, np.float32)
                dur = len(audio) / SR
                if dur < 0.15:
                    await ws.send_text(json.dumps({'type': 'final', 'text': '', 'live_text': '', 'source': 'empty'}))
                    await ws.close(); return
                source = 'qwen3'
                try:
                    text = await qwen3(HTTP, audio, terms, context_text)
                except Exception as e:
                    log.warning('qwen3 failed, using Nemotron: %s', e)
                    text, source = None, 'nemotron'
                q_ms = (time.time() - t_end) * 1000

                async def nemotron_tail():
                    await busy.wait()
                    s = stream or LiveStream(NEMO, terms)
                    if pending:
                        s.audio = np.concatenate([s.audio] + pending); pending.clear()
                    return await asyncio.to_thread(s.flush)
                if text is None:
                    text = await nemotron_tail()
                out = {'type': 'final', 'text': text, 'live_text': stream.text if stream else '', 'source': source,
                       'timing': {'audio_s': round(dur, 2), 'qwen_ms': round(q_ms),
                                  'keyup_to_final_ms': round((time.time() - t_end) * 1000)}}
                await ws.send_text(json.dumps(out))
                live = await nemotron_tail() if source == 'qwen3' else text
                log.info('take %.1fs keyup->final %d ms | qwen: %s | nemo: %s', dur,
                         out['timing']['keyup_to_final_ms'], text[:80], live[:80])
                try:
                    await ws.send_text(json.dumps({'type': 'live_final', 'text': live}))
                except Exception:
                    pass   # the app hangs up on `final`
                await ws.close(); return
    except WebSocketDisconnect:
        return
    except Exception as e:
        log.exception('session failed: %s', e)
        try:
            await ws.send_text(json.dumps({'type': 'error', 'message': str(e)[:300]}))
            await ws.close()
        except Exception:
            pass


if __name__ == '__main__':
    import uvicorn
    uvicorn.run(app, host=os.environ.get('HOST', '127.0.0.1'), port=int(os.environ.get('PORT', '8765')), ws_max_size=2**24)

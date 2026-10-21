"""Laptop test client for the GPU gateway (through the SSH tunnel).

  python3 client.py take.wav [more.wav ...]    stream recordings at real speed
  python3 client.py --mic                      hold Enter... speak, press Enter to stop

Terms: --terms "Soniox,SayControl,Qwen" (default: none).
Needs: pip install websockets numpy soundfile (and sounddevice for --mic).
"""
import argparse, asyncio, json, sys, time

import numpy as np
import soundfile as sf
import websockets

SR = 16000
FRAME = 1600   # 100 ms, like the app's mic tap


def load(path):
    a, sr = sf.read(path, dtype='float32')
    if a.ndim > 1:
        a = a.mean(1)
    if sr != SR:
        idx = np.arange(0, len(a), sr / SR)
        a = np.interp(idx, np.arange(len(a)), a).astype(np.float32)
    return (np.clip(a, -1, 1) * 32767).astype('<i2')


async def run(url, frames, terms, realtime=True):
    """frames: async iterator of int16 arrays. Returns the final message."""
    async with websockets.connect(url, max_size=2**24) as ws:
        await ws.send(json.dumps({'type': 'start', 'sample_rate': SR, 'terms': terms}))
        assert json.loads(await ws.recv())['type'] == 'ready'
        last = ['']
        t0 = time.time()

        async def reader():
            async for m in ws:
                j = json.loads(m)
                if j['type'] == 'partial':
                    last[0] = j['text']
                    print(f'\r\033[K  live {time.time() - t0:5.1f}s: {j["text"][-110:]}', end='', flush=True)
                else:
                    return j
        rd = asyncio.create_task(reader())
        async for f in frames:
            await ws.send(f.tobytes())
        t_up = time.time()
        await ws.send(json.dumps({'type': 'end'}))
        final = await rd
        final['client_keyup_to_final_ms'] = round((time.time() - t_up) * 1000)
        print()
        return final


async def file_frames(pcm):
    t0 = time.time()
    for i in range(0, len(pcm), FRAME):
        yield pcm[i:i + FRAME]
        await asyncio.sleep(max(0, t0 + (i + FRAME) / SR - time.time()))


async def mic_frames():
    import sounddevice as sd
    q = asyncio.Queue(); loop = asyncio.get_running_loop(); stop = asyncio.Event()
    stream = sd.InputStream(samplerate=SR, channels=1, dtype='int16', blocksize=FRAME,
                            callback=lambda d, *_: loop.call_soon_threadsafe(q.put_nowait, d[:, 0].copy()))
    loop.run_in_executor(None, lambda: (input(), loop.call_soon_threadsafe(stop.set)))
    print('Recording... press Enter to stop.')
    with stream:
        while not stop.is_set():
            try:
                yield await asyncio.wait_for(q.get(), 0.2)
            except asyncio.TimeoutError:
                pass
    while not q.empty():
        yield q.get_nowait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('files', nargs='*')
    ap.add_argument('--mic', action='store_true')
    ap.add_argument('--url', default='ws://127.0.0.1:8765/v1/listen')
    ap.add_argument('--terms', default='')
    a = ap.parse_args()
    terms = [t.strip() for t in a.terms.split(',') if t.strip()]
    if a.mic:
        while True:
            r = asyncio.run(run(a.url, mic_frames(), terms))
            print(json.dumps(r, indent=1))
            if input('Again? [Y/n] ').strip().lower() == 'n':
                break
        return
    for f in a.files:
        pcm = load(f)
        print(f'{f}  ({len(pcm) / SR:.1f} s)')
        r = asyncio.run(run(a.url, file_frames(pcm), terms))
        print(f'  FINAL ({r.get("source")}): {r.get("text")}')
        print(f'  timing: {r.get("timing")}  client key-up->final {r["client_keyup_to_final_ms"]} ms')


if __name__ == '__main__':
    main()

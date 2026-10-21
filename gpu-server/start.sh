#!/bin/bash
# Run on the pod: starts Qwen3 (vLLM, 127.0.0.1:8000) and the gateway (127.0.0.1:8765).
# Logs: /workspace/sayctrl-gpu/logs/{qwen,gateway}.log
cd /workspace/sayctrl-gpu
mkdir -p logs
export HF_HOME=/workspace/.cache/huggingface
# /root is container disk and a pod stop wipes it; the NeMo env is backed up on the volume.
[ -x /root/nemo-env/bin/python ] || cp -a /workspace/sayctrl-gpu/nemo-env-backup /root/nemo-env
if ! curl -sf 127.0.0.1:8000/v1/models >/dev/null; then
  HF_HUB_ENABLE_HF_TRANSFER=0 nohup /workspace/vllm-env/bin/qwen-asr-serve Qwen/Qwen3-ASR-1.7B \
    --api-server-count 2 --gpu-memory-utilization 0.35 --max-model-len 4096 --chat-template /workspace/sayctrl-gpu/qwen_en.jinja \
    --host 127.0.0.1 --port 8000 > logs/qwen.log 2>&1 &
  for i in $(seq 1 90); do curl -sf 127.0.0.1:8000/v1/models >/dev/null && break; sleep 2; done
fi
pkill -f "sayctrl-gpu/server.py" 2>/dev/null; sleep 1
nohup /root/nemo-env/bin/python /workspace/sayctrl-gpu/server.py > logs/gateway.log 2>&1 &
for i in $(seq 1 90); do curl -sf 127.0.0.1:8765/health && echo && exit 0; sleep 2; done
echo "gateway did not come up; see logs/gateway.log"; tail -30 logs/gateway.log; exit 1

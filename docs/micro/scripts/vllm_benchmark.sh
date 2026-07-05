#!/bin/bash
# vLLM benchmark script - runs inside container
# Tests matched input/output length pairs only (3 pairs × 4 prompt counts = 12 cases)
#
# CRITICAL: --tokenizer must point to LOCAL model path to avoid network timeout
#           --model must match --served-model-name (not filesystem path) to avoid 404

MODEL_PATH="/models/Qwen3-14B"
SERVED_MODEL_NAME="Qwen3-14B"
LOG_FILE="/root/vllm_benchmark.log"
PORT=8000

> "$LOG_FILE"
# Matched pairs only: input=output
lens=(256 512 1024)
num_prompts_list=(1 10 50 100)

echo "=========================================" | tee -a "$LOG_FILE"
echo " vLLM Benchmark - ${SERVED_MODEL_NAME} (TP4/PP2)" | tee -a "$LOG_FILE"
echo " Cases: 3 lens × 4 prompts = 12 total" | tee -a "$LOG_FILE"
echo " Start: $(date)" | tee -a "$LOG_FILE"
echo "=========================================" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

for len in "${lens[@]}"; do
  for num_prompts in "${num_prompts_list[@]}"; do
    echo "===== Starting: input=$len output=$len prompts=$num_prompts =====" | tee -a "$LOG_FILE"
    vllm bench serve --port "$PORT" \
        --model "$SERVED_MODEL_NAME" \
        --served-model-name "$SERVED_MODEL_NAME" \
        --tokenizer "$MODEL_PATH" \
        --ignore_eos \
        --random-input-len "$len" \
        --random-output-len "$len" \
        --num-prompts "$num_prompts" \
        2>&1 | tee -a "$LOG_FILE"
    echo "===== Completed: input=$len output=$len prompts=$num_prompts =====" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
  done
done

echo "=========================================" | tee -a "$LOG_FILE"
echo " All 12 cases completed: $(date)" | tee -a "$LOG_FILE"
echo "=========================================" | tee -a "$LOG_FILE"

#!/bin/bash
MODEL_PATH="/models/Qwen3.6-35B-A3B-FP8"
SERVED_MODEL_NAME="Qwen3.6-35B-A3B-FP8"
LOG_FILE="/root/vllm_benchmark_concurrent.log"
PORT=8000

> "$LOG_FILE"
input_lens=(256 512 1024)
output_lens=(256 512 1024)
num_prompts_list=(1 10 50 100)

for input_len in "${input_lens[@]}"; do
  for output_len in "${output_lens[@]}"; do
    for num_prompts in "${num_prompts_list[@]}"; do
      echo "===== Starting test: random-input-len=$input_len, random-output-len=$output_len, num-prompts=$num_prompts =====" | tee -a "$LOG_FILE"
      vllm bench serve --port "$PORT" --model "$MODEL_PATH" --served-model-name "$SERVED_MODEL_NAME" --ignore_eos \
        --random-input-len "$input_len" --random-output-len "$output_len" --num-prompts "$num_prompts" \
        2>&1 | tee -a "$LOG_FILE"
      echo "===== Test completed: random-input-len=$input_len, random-output-len=$output_len, num-prompts=$num_prompts =====" | tee -a "$LOG_FILE"
      echo "" | tee -a "$LOG_FILE"
    done
  done
done

echo "All test cases completed. Logs saved to $LOG_FILE"

#!/bin/bash

HF_CACHE_DIR="${HOME}/.cache/huggingface"
DATA_DIR="${HOME}/llm-d-router/data"
DATASET="anon8231489123/ShareGPT_Vicuna_unfiltered"
JSON="ShareGPT_V3_unfiltered_cleaned_split.json"
DS_NAME=$(basename -s .json "${JSON}")
OUTPUT="${DS_NAME}-converted"

LLM_D_INFERENCE_SIM_DIR="${HOME}/llm-d-inference-sim"
MODEL="meta-llama/Llama-3.1-70B-Instruct"
VLLM_IMAGE="vllm/vllm-openai-cpu:v0.21.0"

# Download dataset (a specific JSON file from it, to be exact)
if [ ! -f "${DATA_DIR}/${JSON}" ]; then
    echo "Downloading dataset..."
    hf download --type dataset --cache-dir "${HF_CACHE_DIR}" --local-dir "${DATA_DIR}" "${DATASET}" "${JSON}"
fi

# Convert JSON to a Sqlite3 database appropriate for llm-d-inference-sim
if [ ! -d "${LLM_D_INFERENCE_SIM_DIR}" ]; then
    echo "Cloning llm-d-inference-sim..."
    git clone "https://github.com/llm-d/llm-d-inference-sim.git" "${LLM_D_INFERENCE_SIM_DIR}"
fi

if [ ! -f "${LLM_D_INFERENCE_SIM_DIR}/bin/ds_tool" ]; then
    echo "Building ds-tool..."
    cd "${LLM_D_INFERENCE_SIM_DIR}/bin/ds_tool"
    make ds-tool-build
    cd -
fi

if [ ! -f "${DATA_DIR}/${OUTPUT}.sqlite3" ] || [ ! -f "${DATA_DIR}/${OUTPUT}.json" ] || [ ! -f "${DATA_DIR}/${OUTPUT}.md" ]; then
    echo "Cleaning up leftover files..."
    rm "${DATA_DIR}/${OUTPUT}.sqlite3" "${DATA_DIR}/${OUTPUT}.json" "${DATA_DIR}/${OUTPUT}.md" "${DATA_DIR}/${OUTPUT}.jsonl"
    
    echo "Running vLLM renderer..."
    VLLM_RENDERER=$(docker run \
        --rm \
        -d \
        -v "${HF_CACHE_DIR}":/root/.cache/huggingface \
        -e HF_TOKEN \
        -p 8082:8082 \
        --entrypoint vllm \
        "${VLLM_IMAGE}" launch render "${MODEL}" --port=8082)

    sleep 10  # TODO: replace with healthcheck

    echo "Converting dataset..."
    "${LLM_D_INFERENCE_SIM_DIR}/bin/ds_tool" \
        --local-path "${DATA_DIR}" \
        --input-file "${JSON}" \
        --output-path "${DATA_DIR}" \
        --output-file "${OUTPUT}" \
        --model "${MODEL}" \
        --render-url http://localhost:8082

    echo "Stopping & deleting vLLM renderer..."
    docker rm -f "${VLLM_RENDERER}"

    echo "Converting JSON output to JSONL"
    jq -c '.[] | {"prompt": .input_text, "output_tokens_count": .n_gen_tokens}' "${DATA_DIR}/${OUTPUT}.json" > "${DATA_DIR}/${OUTPUT}.jsonl"
fi

echo "You can pass the following parameters to llm-d-inference-sim:

    --model ${MODEL} \\
    --dataset-path ${DATA_DIR}/${OUTPUT}.sqlite3 \\

You can start GuideLLM with the following command:

guidellm run \\
    --backend kind=openai_http,target=http://localhost:30080 \\
    --tokenizer kind=huggingface_auto,model=${MODEL} \\
    --data kind=json_file,path=${DATA_DIR}/${OUTPUT}.jsonl \\
    --constraint kind=max_duration,seconds=600 \\
    --seed kind=static,value=42 \\
    --output kind=console \\
    --profile kind=synchronous

Or you can send requests directly via cURL:

curl -s http://localhost:30080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  \"model\":\"${MODEL}\",
  \"messages\":[{\"role\":\"user\",\"content\":\"What is Vercel? Explain in simple English\"}],
  \"max_tokens\":128,\"temperature\":0}' | jq
"

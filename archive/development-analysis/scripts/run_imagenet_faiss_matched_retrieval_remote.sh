#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="${IMAGENET_RETRIEVAL_ROOT:-$HOME/fastPLS_results_0.99.39/imagenet_faiss}"
SCRIPT="${IMAGENET_RETRIEVAL_SCRIPT:-$REPO_ROOT/benchmark/benchmark_imagenet_faiss_matched_retrieval.R}"
FAISS_ENV="${FAISSR_ENV:-$HOME/.fastEmbedR/micromamba/envs/fastembedr-faissgpu-cuvs}"
FAISSR_LIB="${FAISSR_LIB:-$HOME/R/faissR_imagenet_lib}"
R_LIB="${FASTPLS_R_LIB:-$HOME/R/x86_64-pc-linux-gnu-library/4.5}"

export LD_LIBRARY_PATH="$FAISS_ENV/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_PRELOAD="$FAISS_ENV/lib/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
export R_LIBS_USER="$FAISSR_LIB:$R_LIB"
export IMAGENET_RETRIEVAL_OUT="$ROOT/results"
export IMAGENET_RETRIEVAL_LABEL_CPP="$REPO_ROOT/benchmark/imagenet_label_crossprod_float32.cpp"
export IMAGENET_RETRIEVAL_TRAIN_N="${IMAGENET_RETRIEVAL_TRAIN_N:-1000000}"
export IMAGENET_RETRIEVAL_EVAL_N="${IMAGENET_RETRIEVAL_EVAL_N:-281167}"
export IMAGENET_RETRIEVAL_MAX_NCOMP="${IMAGENET_RETRIEVAL_MAX_NCOMP:-200}"
export IMAGENET_RETRIEVAL_REPS="${IMAGENET_RETRIEVAL_REPS:-3}"
EXACT_REPS="${IMAGENET_RETRIEVAL_EXACT_REPS:-3}"
IVF_REPS="${IMAGENET_RETRIEVAL_IVF_REPS:-1}"

mkdir -p "$ROOT/results" "$ROOT/logs"

run_monitored() {
  local name="$1"
  shift
  local peak_file="$ROOT/results/${name}_peak_gpu_mb.txt"
  local time_file="$ROOT/logs/${name}.time.txt"
  local log_file="$ROOT/logs/${name}.log"
  local peak=0

  /usr/bin/time -v -o "$time_file" "$@" >"$log_file" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    local used
    used="$(nvidia-smi --query-compute-apps=used_gpu_memory \
      --format=csv,noheader,nounits 2>/dev/null |
      awk '{sum += $1} END {print sum + 0}')"
    if (( used > peak )); then peak="$used"; fi
    sleep 0.2
  done
  wait "$pid"
  printf '%s\n' "$peak" >"$peak_file"
}

run_mode() {
  local name="$1"
  shift
  run_monitored "$name" env "$@" Rscript "$SCRIPT"
}

if [[ ! -f "$ROOT/results/pls_plssvd_n${IMAGENET_RETRIEVAL_TRAIN_N}_k${IMAGENET_RETRIEVAL_MAX_NCOMP}_preparation.csv" ]]; then
  run_mode prepare_pls IMAGENET_RETRIEVAL_MODE=prepare_pls
fi
for space in raw pls; do
  components="100"
  [[ "$space" == "raw" ]] || components="50 100 200"
  for ncomp in $components; do
    for method in exact ivf; do
      name="${space}_k${ncomp}_${method}"
      result="$ROOT/results/${space}_n${IMAGENET_RETRIEVAL_TRAIN_N}_k"
      if [[ "$space" == "raw" ]]; then
        result+="raw"
      else
        result+="$ncomp"
      fi
      result+="_eval${IMAGENET_RETRIEVAL_EVAL_N}_cuda_${method}.csv"
      [[ -f "$result" ]] && continue
      run_mode "$name" \
        IMAGENET_RETRIEVAL_MODE=search \
        IMAGENET_RETRIEVAL_SPACE="$space" \
        IMAGENET_RETRIEVAL_NCOMP="$ncomp" \
        IMAGENET_RETRIEVAL_METHOD="$method" \
        IMAGENET_RETRIEVAL_REPS="$(
          [[ "$method" == "exact" ]] && printf '%s' "$EXACT_REPS" || printf '%s' "$IVF_REPS"
        )"
    done
  done
done

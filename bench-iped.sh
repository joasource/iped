#!/bin/bash
# Benchmark do IPED no Docker: processa a mesma evidencia com varias configuracoes (deteccao de
# rostos, estimativa de idade, faster-whisper...) e compara tempo, resultados, erros e memoria
# (GPU e RAM). Roteiro completo e interpretacao: TESTES-GPU.md
#
# Uso: ./bench-iped.sh <evidencia> [config ...]
#   config:
#     hog | cnn | cnn:<N>              atalhos de rosto (N = iped_numFaceRecognitionProcesses;
#                                      "cnn" sozinho = padrao do IPED, 1 processo por nucleo)
#     <rotulo>@<chave>=<valor>[,...]   qualquer chave dos conf/*Config.txt do IPED, passada como
#                                      -e iped_<chave>=<valor>. Ex.:
#                                        cnn2@faceDetectionModel=cnn,numFaceRecognitionProcesses=2
#                                        idade-cpu@faceDetectionModel=hog,ageDevice=cpu
#                                        cnn2-timeout@faceDetectionModel=cnn,numFaceRecognitionProcesses=2,minTimeout=300
#   padrao: hog cnn:1 cnn:2 cnn:4
# Todas as configs usam iped_ageDevice=$AGE_DEVICE (gpu), salvo se a config trouxer ageDevice.
# A primeira config e a referencia na comparacao de transcricoes e OCR.
# Variaveis: IMAGE (joaca/iped:latest), AGE_DEVICE (gpu), OUT (./bench-<data>), HF_CACHE (~/.cache/huggingface/hub),
#            KEEP=1 mantem saidas e logs (tem nomes e conteudo da evidencia: por padrao sao apagados no fim)
set -uo pipefail
export LC_ALL=C   # lscpu/free/nvidia-smi em ingles, independente do idioma do host

EVID=$(realpath "${1:?uso: $0 <evidencia> [hog|cnn|cnn:N|rotulo@chave=valor,... ...]}"); shift
[ -f "$EVID" ] || { echo "Evidencia nao encontrada: $EVID" >&2; exit 1; }
CONFIGS=("$@"); [ ${#CONFIGS[@]} -eq 0 ] && CONFIGS=(hog cnn:1 cnn:2 cnn:4)
IMAGE=${IMAGE:-joaca/iped:latest}
AGE_DEVICE=${AGE_DEVICE:-gpu}
OUT=$(realpath -m "${OUT:-./bench-$(date +%Y%m%d-%H%M%S)}")
HF_CACHE=${HF_CACHE:-$HOME/.cache/huggingface/hub}
mkdir -p "$OUT" "$HF_CACHE"
RESULTS=$OUT/resultados.tsv

# config -> "rotulo" e lista de chave=valor
parse_config() {
    local cfg=$1
    case "$cfg" in
        hog)     LABEL=hog; KV=(faceDetectionModel=hog) ;;
        cnn)     LABEL=cnn; KV=(faceDetectionModel=cnn) ;;
        cnn:*)   [[ "${cfg#cnn:}" =~ ^[0-9]+$ ]] || return 1
                 LABEL=cnnx${cfg#cnn:}; KV=(faceDetectionModel=cnn numFaceRecognitionProcesses=${cfg#cnn:}) ;;
        *@*)     LABEL=${cfg%%@*}; IFS=, read -ra KV <<< "${cfg#*@}" ;;
        *)       return 1 ;;
    esac
    [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    local kv; for kv in "${KV[@]}"; do [[ "$kv" =~ ^[A-Za-z0-9_]+=.+$ ]] || return 1; done
}
LABELS=()
for cfg in "${CONFIGS[@]}"; do
    parse_config "$cfg" || { echo "Config invalida: $cfg" >&2; exit 1; }
    [[ " ${LABELS[*]-} " == *" $LABEL "* ]] && { echo "Rotulo repetido: $LABEL" >&2; exit 1; }
    LABELS+=("$LABEL")
done

{
    echo "# Maquina"
    echo "- GPU: $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader)"
    echo "- CPU: $(lscpu | sed -n 's/^Model name:[[:space:]]*//p') ($(nproc) threads)"
    echo "- RAM: $(free -g | awk '/^Mem:/{print $2}') GB"
    echo "- Imagem: $IMAGE ($(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null | cut -d@ -f2 | cut -c1-19))"
    echo "- Evidencia: $(basename "$EVID") ($(du -h "$EVID" | cut -f1)), iped_ageDevice=$AGE_DEVICE"
    echo "- Modelos ja no cache ($HF_CACHE): $(ls "$HF_CACHE" 2>/dev/null | sed -n 's/^models--//p' | tr '\n' ' ')"
    echo "- Configs: ${CONFIGS[*]}"
} | tee "$OUT/maquina.md"

COLS="config rc wall_s itens proc_s detect_s features_s arq_rosto rostos idade_ms_rosto audios transcr_ms_audio transcr_chars ocr_itens ocr_chars timeouts erros cudaMalloc gpu_base_MiB gpu_pico_MiB ram_pico_MiB"
echo "$COLS" | tr ' ' '\t' > "$RESULTS"

for cfg in "${CONFIGS[@]}"; do
    parse_config "$cfg"
    name=iped-bench-$LABEL-$$
    d=$OUT/$LABEL; mkdir -p "$d/out" "$d/tmp" "$d/log"
    envs=()
    [[ " ${KV[*]}" == *" ageDevice="* ]] || envs+=(-e iped_ageDevice="$AGE_DEVICE")
    for kv in "${KV[@]}"; do envs+=(-e "iped_$kv"); done

    echo; echo ">>> $LABEL ($(printf '%s ' "${envs[@]}")): $(date +%T)"
    gpu_base=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -lms 500 > "$d/gpu.txt" 2>/dev/null &
    gpu_pid=$!
    ( while sleep 2; do docker stats --no-stream --format '{{.MemUsage}}' "$name" 2>/dev/null; done ) > "$d/ram.txt" &
    ram_pid=$!
    start=$(date +%s)
    docker run --gpus all --rm --name "$name" \
        -v "$(dirname "$EVID")":/evidences:ro -v "$d/out":/output -v "$d/tmp":/mnt/ipedtmp -v "$d/log":/opt/IPED/iped/log \
        -v "$HF_CACHE":/root/.cache/huggingface/hub/ "${envs[@]}" \
        "$IMAGE" java -jar /opt/IPED/iped/iped.jar -d "/evidences/$(basename "$EVID")" -o /output/iped --nogui \
        > "$d/console.log" 2>&1
    rc=$?
    wall=$(( $(date +%s) - start ))
    kill "$gpu_pid" "$ram_pid" 2>/dev/null; wait "$gpu_pid" "$ram_pid" 2>/dev/null

    # Textos de transcricao e OCR (para comparar entre configs); ficam em $d e sao apagados no fim
    docker run --rm -v "$d":/d --entrypoint python "$IMAGE" -c '
import json, os, sqlite3
r = {}
for db, t in (("transcriptions.db", "transcriptions"), ("ocr-results.db", "ocr")):
    p = "/d/out/iped/iped/text/" + db
    r[t] = {str(a): (b or "") for a, b in sqlite3.connect(p).execute("select id, text from " + t)} if os.path.exists(p) else {}
json.dump(r, open("/d/textos.json", "w"))
print(len(r["transcriptions"]), sum(map(len, r["transcriptions"].values())), len(r["ocr"]), sum(map(len, r["ocr"].values())))
' > "$d/textos.txt" 2>/dev/null
    read -r _ tchars ocr_n ocr_chars < "$d/textos.txt" || { tchars=; ocr_n=; ocr_chars=; }

    log=$(ls "$d"/log/*.log 2>/dev/null | head -1)
    get() { [ -n "$log" ] && grep -hoP "$1" "$log" | tail -1; }
    cnt() { if [ -n "$log" ]; then grep -c "$1" "$log"; else echo '?'; fi; }   # grep -c ja imprime 0
    ram_peak=$(awk '{v=$1; u=v; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v);
                     m=(u=="GiB")?v*1024:(u=="MiB")?v:(u=="KiB")?v/1024:0; if (m>p) p=m} END {printf "%d", p}' "$d/ram.txt")
    vals=("$LABEL" "$rc" "$wall"
        "$(get 'Total processed: \K[0-9]+')" "$(get 'Total processed: [0-9]+ items in \K[0-9]+')"
        "$(get 'Time\(s\) to detect faces: \K[0-9]+(\.[0-9])?')" "$(get 'Time\(s\) to get face features: \K[0-9]+(\.[0-9])?')"
        "$(get 'Files for age estimation: \K[0-9]+')" "$(get 'Faces with age estimation performed: \K[0-9]+')"
        "$(get 'Average age estimation time \(ms/face\): \K[0-9]+(\.[0-9])?')"
        "$(get 'Total transcriptions: \K[0-9]+')" "$(get 'Average transcription time \(ms/audio\): \K[0-9]+')" "$tchars"
        "$ocr_n" "$ocr_chars"
        "$(get 'Timeouts: \K[0-9]+')" "$(cnt '\[ERROR\]')" "$(cnt 'cudaMalloc\|CUDA out of memory\|CUDA failed')"
        "$gpu_base" "$(sort -n "$d/gpu.txt" | tail -1)" "$ram_peak")
    (IFS=$'\t'; echo "${vals[*]}") >> "$RESULTS"
    paste <(echo "$COLS" | tr ' ' '\n') <(tail -1 "$RESULTS" | tr '\t' '\n') | column -t | sed 's/^/    /'
    [ "$rc" -ne 0 ] && echo "!!! $LABEL terminou com rc=$rc; veja $d/console.log e $d/log/ (rode com KEEP=1 para nao apagar)"
done

# Tabelas finais (markdown)
{
echo; echo "# Resultados"; echo
echo "## Tempo e memoria"
awk -F'\t' 'NR==1 {print "| config | rc | tempo IPED (s) | tempo total (s) | itens | timeouts | erros | erros de memoria GPU | GPU base (MiB) | pico GPU (MiB) | pico RAM (MiB) |"; print "|---|---|---|---|---|---|---|---|---|---|---|"; next}
            {printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$5,$3,$4,$16,$17,$18,$19,$20,$21}' "$RESULTS"
echo; echo "## Rostos e idade"
awk -F'\t' 'NR==1 {print "| config | deteccao (s) | features (s) | arquivos c/ rosto | rostos | idade (ms/rosto) |"; print "|---|---|---|---|---|---|"; next}
            {printf "| %s | %s | %s | %s | %s | %s |\n", $1,$6,$7,$8,$9,$10}' "$RESULTS"
echo; echo "## Transcricao (faster-whisper) e OCR"
awk -F'\t' 'NR==1 {print "| config | audios | ms/audio | caracteres transcritos | itens com OCR | caracteres de OCR |"; print "|---|---|---|---|---|---|"; next}
            {printf "| %s | %s | %s | %s | %s | %s |\n", $1,$11,$12,$13,$14,$15}' "$RESULTS"
echo; echo "## Comparacao de textos com a 1a config (${CONFIGS[0]})"
docker run --rm -v "$OUT":/b --entrypoint python "$IMAGE" -c '
import json, os, sys
labels = sys.argv[1:]
data = {l: json.load(open(f"/b/{l}/textos.json")) for l in labels if os.path.exists(f"/b/{l}/textos.json")}
if labels[0] not in data: print("(sem textos da referencia)"); sys.exit()
ref = data[labels[0]]
print("| config | transcricoes iguais | transcricoes diferentes | so em um lado | OCR iguais | OCR diferentes | so em um lado |")
print("|---|---|---|---|---|---|---|")
for l in labels[1:]:
    if l not in data: print(f"| {l} | ? | ? | ? | ? | ? | ? |"); continue
    row = [l]
    for k in ("transcriptions", "ocr"):
        a, b = ref[k], data[l][k]
        common = a.keys() & b.keys()
        same = sum(a[i] == b[i] for i in common)
        row += [same, len(common) - same, len(a.keys() ^ b.keys())]
    print("| " + " | ".join(map(str, row)) + " |")
' "${LABELS[@]}" 2>&1
} | tee "$OUT/resultados.md"

# As saidas sao do root (criadas pelo container): apaga via container
if [ "${KEEP:-0}" != 1 ]; then
    docker run --rm -v "$OUT":/b --entrypoint bash "$IMAGE" -c 'cd /b && for x in */; do rm -rf "$x"; done'
    echo; echo "Saidas, logs e textos do IPED apagados (KEEP=1 para manter). Ficaram: $OUT/{maquina.md,resultados.md,resultados.tsv}"
fi

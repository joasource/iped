#!/bin/bash
# Smoke test da stack de GPU. Rodar DENTRO do container, com GPU:
#   docker run --gpus all --rm -v "$PWD/smoke-test.sh":/smoke-test.sh:ro --entrypoint bash <imagem> /smoke-test.sh
# Funciona nas imagens dependencies, processor e final.
# SMOKE_WHISPER_MODEL: modelo do faster-whisper (padrao "tiny"; "skip" nao baixa/carrega modelo).
set -u
FAILED=0

check() {
    local name=$1 out
    shift
    printf '%-30s' "${name}"
    if out=$("$@" 2>&1); then
        echo "OK     ${out##*$'\n'}"
    else
        echo "FALHOU"
        sed 's/^/    /' <<< "${out}"
        FAILED=$((FAILED + 1))
    fi
}

t_gpu()     { nvidia-smi --query-gpu=name,driver_version --format=csv,noheader; }
t_python()  { echo "$(python --version 2>&1) | $(. /etc/os-release && echo "${PRETTY_NAME}") | PYLIB=${PYLIB}"; }
t_java()    { java -version 2>&1 | head -1; }
t_tools()   {
    for b in tesseract convert mplayer tsk_recover ewfinfo; do command -v "${b}" > /dev/null || { echo "binario ausente: ${b}"; return 1; }; done
    ls /usr/share/java/sleuthkit-*.jar > /dev/null || { echo "sleuthkit jar ausente"; return 1; }
    echo "tesseract, imagemagick, mplayer, sleuthkit, libewf presentes"
}

t_torch() {
    python - <<'PY'
import torch
assert torch.cuda.is_available(), "torch.cuda.is_available() == False"
x = torch.randn(1024, 1024, device="cuda")
assert torch.isfinite((x @ x).sum()).item()
print(f"torch {torch.__version__} cuda {torch.version.cuda} cudnn {torch.backends.cudnn.version()} gpu {torch.cuda.get_device_name(0)}")
PY
}

t_dlib() {
    python - <<'PY'
import dlib
assert dlib.DLIB_USE_CUDA, "dlib foi compilado SEM CUDA (rodaria em CPU)"
n = dlib.cuda.get_num_devices()
assert n > 0, "dlib nao enxerga nenhuma GPU"
print(f"dlib {dlib.__version__} CUDA devices={n}")
PY
}

t_face() {
    python - <<'PY'
import numpy as np, face_recognition
face_recognition.face_locations(np.zeros((256, 256, 3), dtype=np.uint8), model="cnn")
print("detector CNN (dlib/cuDNN) executou")
PY
}

t_ctranslate2() {
    python - <<'PY'
import ctranslate2
n = ctranslate2.get_cuda_device_count()
assert n > 0, "ctranslate2 nao enxerga nenhuma GPU"
assert "float16" in ctranslate2.get_supported_compute_types("cuda"), "float16 nao suportado"
print(f"ctranslate2 {ctranslate2.__version__} devices={n} float16 ok")
PY
}

t_whisper() {
    python - <<'PY'
import os, numpy as np
from faster_whisper import WhisperModel
name = os.environ.get("SMOKE_WHISPER_MODEL", "tiny")
model = WhisperModel(name, device="cuda", compute_type="float16")
list(model.transcribe(np.zeros(16000 * 2, dtype=np.float32))[0])
print(f"faster-whisper '{name}' carregou e transcreveu em cuda/float16")
PY
}

# Caminho usado pelo IPED: JVM -> jep -> python -> torch
t_jep() {
    local d jar="${PYLIB}/jep/jep-${JEP_VERSION}.jar"
    d=$(mktemp -d)
    cat > "${d}/JepSmoke.java" <<'JAVA'
import jep.SharedInterpreter;
public class JepSmoke {
    public static void main(String[] a) throws Exception {
        try (SharedInterpreter i = new SharedInterpreter()) {
            i.exec("import sys, torch");
            i.exec("assert torch.cuda.is_available(), 'torch sem CUDA dentro do jep'");
            i.exec("r = 'python ' + sys.version.split()[0] + ', torch ' + torch.__version__ + ', cuda ok'");
            System.out.println("jep -> " + i.getValue("r"));
        }
    }
}
JAVA
    javac -cp "${jar}" -d "${d}" "${d}/JepSmoke.java" \
        && java -Djava.library.path="${PYLIB}/jep" -cp "${d}:${jar}" JepSmoke
}

t_iped_jep() {
    [ -d /opt/IPED/iped/lib ] || { echo "SKIP (imagem sem IPED)"; return 0; }
    cmp "${PYLIB}/jep/jep-${JEP_VERSION}.jar" /opt/IPED/iped/lib/jep-4.0.3.jar && echo "lib/jep-4.0.3.jar == jep ${JEP_VERSION}"
}

check "GPU / driver"        t_gpu
check "Python / distro"     t_python
check "Java"                t_java
check "Ferramentas nativas" t_tools
check "torch + CUDA"        t_torch
check "dlib com CUDA"       t_dlib
check "face_recognition CNN" t_face
check "ctranslate2 (GPU)"   t_ctranslate2
if [ "${SMOKE_WHISPER_MODEL:-tiny}" = "skip" ]; then
    printf '%-30sSKIP\n' "faster-whisper"
else
    check "faster-whisper"  t_whisper
fi
check "JVM -> jep -> torch" t_jep
check "jar do jep no IPED"  t_iped_jep

echo
if [ "${FAILED}" -eq 0 ]; then echo "TODOS OS TESTES PASSARAM"; else echo "${FAILED} TESTE(S) FALHARAM"; fi
exit $((FAILED > 0))

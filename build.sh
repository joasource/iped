#!/bin/bash
# Constroi a imagem de dependencias de uma stack (CUDA + Ubuntu + Python + torch).
# Uso: ./build.sh <stack> [args extras do docker build]     ex.: ./build.sh u2204-cu126
# A stack vem de stacks/<stack>.env. Gera SOMENTE a tag local joaca/iped:dependencies_<stack>
# (nunca sobrescreve joaca/iped:dependencies).
set -euo pipefail
cd "$(dirname "$0")"

STACK=${1:?"uso: $0 <stack>   (stacks disponiveis: $(ls stacks | sed 's/\.env$//' | tr '\n' ' '))"}
shift
[ -f "stacks/${STACK}.env" ] || { echo "Stack '${STACK}' nao existe em stacks/" >&2; exit 1; }

BUILD_ARGS=()
while IFS= read -r line; do
    [[ "${line}" =~ ^[A-Z_0-9]+= ]] && BUILD_ARGS+=(--build-arg "${line}")
done < "stacks/${STACK}.env"

docker build "${BUILD_ARGS[@]}" "$@" . -f Dockerfile.dependencies -t "joaca/iped:dependencies_${STACK}"
echo "Pronto: joaca/iped:dependencies_${STACK}"
echo "Teste (com GPU): docker run --gpus all --rm -v \"\$PWD/smoke-test.sh\":/smoke-test.sh:ro --entrypoint bash joaca/iped:dependencies_${STACK} /smoke-test.sh"

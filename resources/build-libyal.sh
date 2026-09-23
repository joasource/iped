#!/bin/bash
# Compila e instala bibliotecas libyal em /usr.
# Uso: build-libyal.sh nome[@ref] ...   (ref = tag, branch ou commit; sem @ref = master)
# A ordem respeita as dependencias. As bibliotecas dependentes sao buscadas pelo proprio
# synclibs.sh na ultima tag de cada uma.
set -euo pipefail

for spec in "$@"; do
    name=${spec%%@*}
    ref=""
    [[ "${spec}" == *@* ]] && ref=${spec#*@}

    echo "--> libyal/${name} (${ref:-master})"
    # fetch do ref exato (e nao clone + checkout): o libyal reescreve o master com force-push e o
    # commit fixado deixa de vir no clone, mas o GitHub ainda o entrega quando pedido pelo SHA
    # (ex.: libesedb 08bf68f, substituido no master em 2026-09-23).
    git init --quiet "${PKGTMPDIR}/${name}"
    cd "${PKGTMPDIR}/${name}"
    git fetch --quiet --depth 1 "https://github.com/libyal/${name}" "${ref:-HEAD}"
    git checkout --quiet FETCH_HEAD
    ./synclibs.sh && ./autogen.sh && ./configure --prefix=/usr && make all install
    cd / && rm -rf "${PKGTMPDIR}/${name}"
done

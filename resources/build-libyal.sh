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
    git clone --quiet "https://github.com/libyal/${name}" "${PKGTMPDIR}/${name}"
    cd "${PKGTMPDIR}/${name}"
    if [ -n "${ref}" ]; then git checkout --quiet "${ref}"; fi
    ./synclibs.sh && ./autogen.sh && ./configure --prefix=/usr && make all install
    cd / && rm -rf "${PKGTMPDIR}/${name}"
done

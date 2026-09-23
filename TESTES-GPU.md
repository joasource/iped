# Testes de desempenho do IPED no Docker (GPU)

Roteiro para medir, em outro computador, qual configuração do `joaca/iped` rende mais naquele
hardware: detector de rostos (`hog` × `cnn` e número de processos) e estimativa de idade na GPU,
com o faster-whisper large-v3-turbo (fixo em float16) dividindo a GPU com eles. Serve para uma
pessoa seguir ou para abrir uma sessão do Claude Code no repositório e pedir: *"siga o
TESTES-GPU.md nesta máquina"*.

O teste é automatizado pelo `bench-iped.sh`: ele processa a mesma evidência com cada
configuração e imprime as tabelas de tempo, resultados, erros e memória (GPU e RAM).

---

## 1. Pré-requisitos

| Item | Como conferir | Observação |
|---|---|---|
| Driver NVIDIA | `nvidia-smi` | A imagem usa CUDA 12.6: driver ≥ 560 |
| Docker + NVIDIA Container Toolkit | `docker run --rm --gpus all ubuntu nvidia-smi` | Instalação no README (seção WSL/Ubuntu) |
| Disco livre | `df -h /var/lib/docker` | ~35 GB para a imagem + saída do teste |
| Repositório | `git clone https://github.com/joasource/iped && cd iped` | Traz `bench-iped.sh` e `smoke-test.sh` |
| Evidência de teste | um arquivo (zip, E01, ufdr...) | Ver abaixo |

**Evidência:** precisa ter **imagens com rostos** (para rostos/idade) e **áudios** (para o
whisper). Uma evidência pequena (~100 MB, ~2.500 itens, algumas dezenas de áudios) roda cada
configuração em 3–8 min. Com poucos áudios, a medição do whisper é só indicativa: para ajustar o
whisper, use uma evidência com mais áudio.

**Sigilo:** os logs, saídas e textos do IPED têm nomes, caminhos e conteúdo da evidência. O
script apaga tudo no fim (a não ser com `KEEP=1`) e deixa só as tabelas com números. Nunca
versionar saídas nem colar trechos de transcrição/OCR em arquivos do repositório.

---

## 2. Passo a passo

### 2.1 Máquina e imagem

```bash
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
lscpu | grep 'Model name'; nproc; free -g
docker pull joaca/iped:latest            # ~33 GB; demora
```

### 2.2 Smoke test (GPU funcionando dentro do container)

```bash
docker run --gpus all --rm -v "$PWD/smoke-test.sh":/smoke-test.sh:ro \
  --entrypoint bash joaca/iped:latest /smoke-test.sh
```

Tem que terminar com `TODOS OS TESTES PASSARAM` (11 itens: torch+CUDA, dlib com CUDA,
face_recognition CNN, ctranslate2, faster-whisper, JVM → jep → torch...). Se falhar, pare aqui:
o problema é de driver/toolkit, não de configuração.

### 2.3 Aquecimento (baixar os modelos)

Na primeira execução o IPED baixa os modelos do HuggingFace (whisper large-v3-turbo ~1,6 GB,
modelo de idade) para `~/.cache/huggingface/hub`, o que distorce o tempo. Rode uma vez e
descarte o resultado:

```bash
./bench-iped.sh /caminho/evidencia.zip hog
```

### 2.4 Rostos: detector e número de processos

```bash
./bench-iped.sh /caminho/evidencia.zip hog cnn:1 cnn:2 cnn:4 cnn
```

- `hog`: detector só de CPU (o dlib não tem HOG na GPU). Rápido, acha menos rostos.
- `cnn:N`: detector na GPU com N processos de reconhecimento de rosto.
- `cnn` sozinho: padrão do IPED = **1 processo por núcleo lógico**. Cada processo carrega o
  modelo na GPU; em máquinas com muitos núcleos isso estoura a VRAM (erros `cudaMalloc`) e
  **perde rostos em silêncio**. Vale rodar para ver se acontece na máquina.

### 2.5 Transcrição: faster-whisper (fixo)

O whisper é **sempre** `dropbox-dash/faster-whisper-large-v3-turbo`, `device = gpu`,
`precision = float16` (padrão da imagem; não variar). O IPED abre 1 processo de whisper por GPU,
que fica carregado a execução inteira e divide a VRAM com o detector `cnn` e a estimativa de
idade. Por isso o script mede o whisper **em cada configuração de rosto**:

- **ms/áudio**: sobe quando o `cnn` com muitos processos disputa a GPU;
- **caracteres transcritos e comparação de textos**: devem ficar iguais (ou quase) entre as
  configs; diferença grande indica transcrição falhando (timeout ou falta de memória);
- **pico de GPU**: o turbo em float16 ocupa alguns GB fixos; a folga que sobra é o que limita
  o número de processos `cnn`.

Se o whisper der timeout em áudios longos, os ajustes são `iped_minTimeout` (padrão 180 s) e
`iped_timeoutPerSec` (padrão 3 s por segundo de áudio). Não mexa em `device`/`batchSize` por
variável: essas chaves existem também em outros arquivos (idade, classificador remoto) e a
variável muda todos.

### 2.6 Combinação final

Rode a melhor config de rosto contra a atual, de preferência numa evidência com mais áudio, para
confirmar o ganho e ver o whisper sob carga. Por exemplo:

```bash
./bench-iped.sh /caminho/evidencia.zip \
  atual@faceDetectionModel=hog \
  proposta@faceDetectionModel=cnn,numFaceRecognitionProcesses=2
```

Cada configuração roda uma vez; a variação entre execuções chegou a ~20% no tempo total. Para
decidir entre duas configs próximas, repita as duas (em ordem inversa).

---

## 3. O que o script mede

Saída em `bench-<data>/`: `maquina.md`, `resultados.md` (tabelas) e `resultados.tsv`.

| Métrica | De onde vem |
|---|---|
| tempo IPED / tempo total (s) | `Total processed: ... in X seconds` do log / relógio (inclui subir o container e carregar modelos) |
| detecção / features (s) | `[FaceRecognitionTask] Time(s) to detect faces` / `to get face features` (soma dos processos) |
| arquivos c/ rosto, rostos | `AgeEstimationTask: Files for age estimation` / `Faces with age estimation performed` |
| idade (ms/rosto) | `Average age estimation time (ms/face)` |
| áudios, ms/áudio | `Total transcriptions` / `Average transcription time (ms/audio)` |
| caracteres transcritos, OCR | `text/transcriptions.db` e `text/ocr-results.db` da saída |
| comparação de textos | por item, contra a 1ª config: iguais / diferentes / só em um lado |
| erros de memória GPU | linhas com `cudaMalloc`, `CUDA out of memory` ou `CUDA failed` no log |
| pico GPU (MiB) | `nvidia-smi` a cada 0,5 s (GPU inteira: inclui outros processos; ver "GPU base") |
| pico RAM (MiB) | `docker stats` do container a cada 2 s (memória do cgroup do container) |

---

## 4. Como decidir

1. **Descarte** qualquer config com `rc` ≠ 0, erros de memória GPU > 0 ou rostos a menos que
   outra config do mesmo detector: está perdendo resultado.
2. **Rostos:** entre as `cnn:N` sem erro, escolha a de menor tempo. Mais processos não é mais
   rápido: todos disputam a mesma GPU. Compare com o `hog` em tempo × rostos encontrados.
3. **Whisper (turbo, float16):** o `ms/áudio` não deve piorar muito com o `cnn`, e a comparação
   de textos deve dar (quase) tudo igual à referência. Se piorar, reduza os processos `cnn`.
4. **Folga de VRAM:** pico GPU a menos de ~1 GB do total é arriscado em casos grandes (mais
   áudios e imagens em paralelo). Prefira a config com folga.
5. `hog` e `cnn` encontram conjuntos diferentes de rostos: trocar o detector muda o resultado
   pericial (casos antigos com `hog` não são diretamente comparáveis).

---

## 5. Formato da resposta (o que reportar)

Para cada máquina, entregar:

1. **Máquina:** GPU (VRAM, driver), CPU (threads), RAM, digest da imagem, evidência (tamanho).
2. **Tabelas** do `resultados.md` (tempo e memória; rostos e idade; transcrição e OCR;
   comparação de textos), com uma linha de leitura embaixo de cada uma.
3. **Achados:** o que surpreendeu (ex.: config padrão estourando VRAM), com o número que prova.
4. **Recomendação** para aquela máquina, com o comando pronto:

```bash
docker run --gpus all --rm \
  -v /mnt/evidencias:/evidences:ro -v ~/ipedtmp:/mnt/ipedtmp -v ~/saida:/output \
  -v ~/.cache/huggingface/hub:/root/.cache/huggingface/hub/ \
  -e iped_ageDevice=gpu \
  -e iped_faceDetectionModel=cnn -e iped_numFaceRecognitionProcesses=2 \
  joaca/iped java -jar /opt/IPED/iped/iped.jar -d /evidences/caso.E01 -o /output/caso
```

5. **Limites da medição:** 1 execução por config, quantos áudios havia, o que não foi testado.

---

## 6. Armadilhas (já aconteceram)

- **`--nogui` é obrigatório** em processamento sem tela: sem ele o IPED morre em 5 s com
  `HeadlessException` (o console só mostra `ERROR!!!`; o motivo está no log do IPED, dentro
  do container — por isso o script monta `/opt/IPED/iped/log`).
- **Arquivos criados pelo container são do root.** Para apagar sem sudo:
  `docker run --rm -v "$DIR":/x --entrypoint bash joaca/iped:latest -c 'rm -rf /x/<pasta>'`.
- **Variável não definida em script gerado** vira caminho na raiz (`-v $S/log:` com `$S` vazio
  criou `/log-...` no host). Conferir os `-v` antes de rodar.
- **Processos em segundo plano:** `setsid` pode fazer fork e o `$!` não é o PID real (use
  `setsid -w`). Não usar `pkill -f <padrão>` num comando que contém o padrão (mata o próprio
  shell): matar por PID ou `docker kill` pelo nome do container (`iped-bench-*`).
- **Não editar o `bench-iped.sh` enquanto ele roda**: o bash lê o script aos poucos.
- **Pico de GPU é da placa inteira**: feche outros usos da GPU (ex.: ollama, navegador com
  aceleração) ou desconte a coluna "GPU base".
- **Primeira execução baixa modelos** (seção 2.3).

---

## 7. Referência: RTX 3060 12 GB, Ryzen 5 3600 (12 threads), 16 GB RAM

Imagem `latest` = u2404-cu126-py312 (Ubuntu 24.04, Python 3.12, CUDA 12.6), evidência zip de
93 MB / 2.487 itens / 26 áudios, `iped_ageDevice=gpu`, whisper turbo float16 (2026-09-23).

Saída do `./bench-iped.sh <zip> hog cnn:2`:

| config | tempo IPED (s) | detecção (s) | arquivos c/ rosto | rostos | idade (ms/rosto) | whisper (ms/áudio) | pico GPU (MiB) | pico RAM (MiB) |
|---|---|---|---|---|---|---|---|---|
| hog | 173 | 11,3 | 147 | 166 | 5,6 | 1.662 | 4.832 | 973 |
| cnn:2 | 168 | 55,9 | 189 | **226** | 4,6 | 1.388 | 7.764 | 968 |

Transcrições (26/26) e OCR (1.008/1.008) idênticos entre as duas: o detector não interfere no
whisper nem no OCR.

Execuções avulsas anteriores (mesma máquina e evidência), variando os processos `cnn`:

| config | tempo IPED (s) | rostos | erros de memória GPU | pico GPU (MiB) |
|---|---|---|---|---|
| cnn (padrão: 12 processos) | 494 | 213 (perdeu rostos) | **3** | 11.869 |
| cnn:4 | 382 | 226 | 0 | 10.749 |
| cnn:2 | 201 | 226 | 0 | 11.063 |

- `cnn` acha ~36% mais rostos que `hog`; com 2 processos, no mesmo tempo que o `hog`.
- O padrão do IPED (1 processo por núcleo) estoura os 12 GB e perde rostos; 4 processos já é
  mais lento que 2 (disputa pela GPU).
- O pico de GPU da mesma config variou entre execuções (cnn:2: 7,8 a 11,1 GB), conforme
  whisper, idade e `cnn` coincidem no tempo. Olhe o pior caso.
- Idade: CPU e GPU dão os mesmos rótulos; GPU ~20× mais rápida (63,9 → 3,1 ms/rosto).
- Whisper em `int8_float16` (testado uma vez, **não usar**): 1,4 s/áudio, mas 21 das 26
  transcrições mudaram em relação ao float16.

**Recomendação para esta máquina:** `iped_faceDetectionModel=cnn`,
`iped_numFaceRecognitionProcesses=2`, `iped_ageDevice=gpu`, whisper no padrão (turbo float16).

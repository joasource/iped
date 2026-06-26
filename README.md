# joaca/iped

Este repositório é um fork especializado do `iped-docker/iped`, adaptado para o meu fluxo de trabalho. O foco aqui é **performance bruta e recursos avançados**, utilizando **Whisper** para transcrição de áudio, **reconhecimento facial** de alta performance e suporte nativo à **aceleração via GPU NVIDIA (CUDA)**.

> **Nota:** Certifique-se de ter o `nvidia-container-toolkit` instalado no seu host para que a GPU seja mapeada corretamente para dentro dos containers.

***

## 💡 Dicas Rápidas (Para quem não quer perder tempo)

##### ⚡ Instalação Rápida (Recomendado)

A forma mais rápida de ter o IPED pronto para uso é baixar a imagem diretamente do Docker Hub, sem necessidade de compilação:

```bash
docker pull joaca/iped:snapshot
```
Ou para o release stable 4.3.0:
```bash
docker pull joaca/iped:v4.3.0
```

### 🛠️ Workflow de Compilação Local (Build)

Se você precisa construir as imagens na sua própria máquina — seja para aplicar modificações, auditar o código ou adaptar para o seu ambiente no GAECO — utilize o processo de *build* seguindo esta ordem lógica.

#### 1. Construindo a Imagem Base (Dependências)

Esta etapa é a mais demorada, pois compila bibliotecas forenses, CUDA e PyTorch. Ela é feita separadamente para que o Docker possa usar o *cache* e evitar reprocessar tudo toda vez que você alterar apenas o código do IPED.

```bash
docker build . -f Dockerfile.dependencies -t joaca/iped:dependencies

```

#### 2. Construindo a Imagem do Processador (IPED)

Após ter a base, compilamos a versão do IPED propriamente dita. Escolha uma das opções abaixo conforme a sua necessidade:

**Opção A: Versão Estável (Release)**
Ideal para rodar uma versão oficial testada. Substitua `4.3.0` pela versão desejada.

```bash
docker build \
  --build-arg SNAPSHOT=false \
  --build-arg IPED_RELEASE_VERSION=4.3.0 \
  -f Dockerfile.processor \
  -t joaca/iped:v4.3.0 .

```

**Opção B: Versão Snapshot (Automática)**
Utiliza um artefato gerado via GitHub Actions. Para isso, você precisará de um `Personal Access Token` (PAT) do GitHub.

**Passo 1: Criando seu Token (PAT)**

1. No GitHub, clique na sua foto de perfil > **Settings**.
2. No menu lateral esquerdo, vá em **Developer settings** > **Personal access tokens** > **Tokens (classic)**.
3. Clique em **Generate new token (classic)**.
4. Dê um nome (ex: `build-iped`), marque a permissão `repo` (especialmente `repo:status` e `public_repo`) e a permissão `workflow`.
5. Clique em **Generate token** e copie o código (ele começa com `ghp_...`). **Guarde-o bem**, pois não aparecerá novamente.

**Passo 2: Exportando o Token no terminal**
Antes de buildar, exporte o token para a sessão do seu terminal:

```bash
export ACTION_GH_TOKEN="seu_token_aqui"

```

**Passo 3: Executando o Build**

```bash
docker build \
  --build-arg SNAPSHOT=true \
  --build-arg SNAPSHOT_WORKFLOW_ID=ID_DO_WORKFLOW \
  --secret id=ACTION_GH_TOKEN,env=ACTION_GH_TOKEN \
  -f Dockerfile.processor \
  -t joaca/iped:snapshot .

```

*Nota: Para encontrar o `SNAPSHOT_WORKFLOW_ID`, acesse a página de [Actions do repositório oficial do IPED](https://github.com/sepinf-inc/IPED/actions). Clique na execução do workflow desejado (o "run") e observe o número de identificação que aparece na URL do seu navegador (ex: `.../actions/runs/28046804277` — o ID é `28046804277`).*

### Último passo nos dois casos:
```bash
docker build . -t joaca/iped
```

---

### 🖥️ Configurando o ambiente (`dkr.source`)

Para rodar o IPED com interface gráfica (X11) e com as permissões de GPU corretas, utilize o script `dkr.source`. Ele cria a função `dkr` que facilita o deploy:

```bash
# Carregue o script no seu terminal
source dkr.source

# Agora basta usar o comando 'dkr' para executar os containers
dkr joaca/iped

```

**Conteúdo do `dkr.source`:**

```bash
#!/bin/bash
dkr () 
{
  xhost + > /dev/null 2>&1

  # Resolve a treta do X11 no WSLg vs Linux Nativo
  if [ -d "/mnt/wslg/.X11-unix" ]; then
      X11_SOCKET="/mnt/wslg/.X11-unix"
  else
      X11_SOCKET="/tmp/.X11-unix"
  fi

  # Só injeta os devices de vídeo/áudio se eles existirem no host
  DEVICES=""
  if [ -e "/dev/dri" ]; then
      DEVICES="$DEVICES --device /dev/dri"
  fi
  if [ -e "/dev/snd" ]; then
      DEVICES="$DEVICES --device /dev/snd"
  fi

  docker run --gpus all --rm -it -v "`pwd`":"`pwd`":Z \
          -e DISPLAY=$DISPLAY -e GDK_BACKEND \
          -e GDK_SCALE \
          -e GDK_DPI_SCALE \
          -e QT_DEVICE_PIXEL_RATIO \
          -e LANG=C.UTF-8 \
          -e LC_ALL=C.UTF-8 \
          -e NO_AT_BRIDGE=1 \
          $DEVICES \
          -v /etc/localtime:/etc/localtime:ro \
          -v $X11_SOCKET:/tmp/.X11-unix "$@"
}
export -f dkr

```

---

## 🚀 Executando os Containers

**Dica de ouro:** Use volumes em discos **SSD** para `/mnt/ipedtmp` e `/mnt/hashesdb`. Se o I/O for lento, não adianta ter uma GPU de ponta.

### Comando para Processamento (Batch/Headless)

Para execução do indexador com interface gráfica:

```bash
sudo dkr -v /mnt/evidences:/evidences \
   -v ~/ipedtmp:/mnt/ipedtmp \
   -v ~/ipedlog:/opt/IPED/iped/log \
   -v ~/output:/output \
   -v ~/.cache/huggingface/hub:/root/.cache/huggingface/hub/ \
    joaca/iped java -jar /opt/IPED/iped/iped.jar \
   -d /evidences/evidence.ufdr \
   -o /output/IPED_OUTPUT

```

### Comando para Análise (Interface Gráfica)

Após o processamento, abra o resultado na interface do IPED:

```bash
sudo dkr -v /mnt/evidences:/evidences \
         -v /mnt/ipedtmp:/mnt/ipedtmp \
         joaca/iped java -jar \
         /evidences/iped-output/iped/lib/iped-search-app.jar

```

---

## 🛠️ Por que este Fork?

O `joaca/iped` foi refinado para:

* **Integração com Whisper:** Transcrição de áudio via GPU.
* **Reconhecimento Facial:** Ajustado para rodar nativamente com CUDA.
* **Performance:** Remoção de imagens antigas do *transcriptor* que causavam conflitos e ocupavam espaço desnecessário.
* **Otimização:** Containers slim preparados para o seu ambiente.

---

## ⚙️ Configurações Avançadas (Runtime)

Conforme trazido pelo ipeddocker/iped, é possível que você ajuste o comportamento do motor forense em tempo de execução utilizando variáveis de ambiente (-e). Basta definir a variável desejada no comando `docker run` ou `dkr` usando o prefixo `iped_`.

As variáveis suportadas são:

```
iped_locale=
iped_indexTemp=
iped_indexTempOnSSD=
iped_outputOnSSD=
iped_numThreads=
iped_hashesDB=
iped_tskJarPath=
iped_mplayerPath=
iped_pluginFolder=
iped_regripperFolder=
iped_enableHash=
iped_enablePhotoDNA=
iped_enableHashDBLookup=
iped_enablePhotoDNALookup=
iped_enableLedDie=
iped_enableYahooNSFWDetection=
iped_enableQRCode=
iped_ignoreDuplicates=
iped_exportFileProps=
iped_processFileSignatures=
iped_enableFileParsing=
iped_expandContainers=
iped_processEmbeddedDisks=
iped_enableRegexSearch=
iped_enableAutomaticExportFiles=
iped_enableLanguageDetect=
iped_enableNamedEntityRecogniton=
iped_enableGraphGeneration=
iped_entropyTest=
iped_enableSplitLargeBinary=
iped_indexFileContents=
iped_enableIndexToElasticSearch=
iped_enableMinIO=
iped_enableAudioTranscription=
iped_enableCarving=
iped_enableLedCarving=
iped_enableKnownMetCarving=
iped_enableImageThumbs=
iped_enableImageSimilarity=
iped_enableFaceRecognition=
iped_enableVideoThumbs=
iped_enableDocThumbs=
iped_enableHTMLReport=
iped_convertCommand=
iped_language=
iped_maxConcurrentRequests=
iped_mimesToProcess=
iped_requestIntervalMillis=
iped_serviceRegion=
iped_timeout=
iped_connect_timeout_millis=
iped_max_async_requests=
iped_min_bulk_items=
iped_min_bulk_size=
iped_protocol=
iped_timeout_millis=
iped_useCustomAnalyzer=
iped_validateSSL=
iped_hashes=
iped_retries=
iped_timeOut=
iped_updateRefsToMinIO=
iped_zipFilesMaxSize=
iped_enableExternalConv=
iped_externalConversionTool=
iped_extractThumb=
iped_galleryThreads=
iped_highResDensity=
iped_imgConvTimeout=
iped_imgConvTimeoutPerMB=
iped_imgThumbSize=
iped_logGalleryRendering=
iped_lowResDensity=
iped_maxMPixelsInMemory=
iped_excludeKnown=
iped_supportedMimes=
iped_supportedMimesWithLinks=
iped_autoManageCols=
iped_backupInterval=
iped_embedLibreOffice=
iped_maxBackups=
iped_openImagesCacheWarmUpEnabled=
iped_openImagesCacheWarmUpThreads=
iped_openWithDoubleClick=
iped_preOpenImagesOnSleuth=
iped_searchThreads=
iped_maxSimilarityDistance=
iped_searchRotatedAndFlipped=
iped_statusHashDBFilter=
iped_EnableCategoriesList=
iped_EnableImageThumbs=
iped_EnableThumbsGallery=
iped_EnableVideoThumbs=
iped_Examiner=
iped_FramesPerStripe=
iped_Header=
iped_Investigation=
iped_ItemsPerPage=
iped_Material=
iped_Record=
iped_RecordDate=
iped_Report=
iped_ReportDate=
iped_RequestDate=
iped_RequestDoc=
iped_Requester=
iped_ThumbSize=
iped_ThumbsPerPage=
iped_Title=
iped_VideoStripeWidth=
iped_faceDetectionModel=
iped_maxResolution=
iped_upSampling=
iped_commitIntervalSeconds=
iped_convertCharsToAscii=
iped_convertCharsToLowerCase=
iped_extraCharsToIndex=
iped_filterNonLatinChars=
iped_forceMerge=
iped_indexUnallocated=
iped_maxTokenLength=
iped_storeTermVectors=
iped_textSplitSize=
iped_useNIOFSDirectory=
iped_GalleryThumbs=
iped_Layout=
iped_Timeouts=
iped_Verbose=
iped_enableVideoThumbsOriginalDimension=
iped_enableVideoThumbsSubitems=
iped_maxDimensionSize=
iped_categoriesToIgnore=
iped_mimeTypesToIgnore=
iped_OCRLanguage=
iped_enableOCR=
iped_externalConvMaxMem=
iped_externalPdfToImgConv=
iped_maxConvImageSize=
iped_maxFileSize2OCR=
iped_maxPDFTextSize2OCR=
iped_minFileSize2OCR=
iped_pageSegMode=
iped_pdfToImgLib=
iped_pdfToImgResolution=
iped_processNonStandard=
iped_addFileSlacks=
iped_addUnallocated=
iped_ignoreHardLinks=
iped_minOrphanSizeToIgnore=
iped_numImageReaders=
iped_robustImageReading=
iped_skipFolderRegex=
iped_unallocatedFragSize=
iped_fragmentOverlapSize=
iped_itemFragmentSize=
iped_minItemSizeToFragment=
iped_libreOfficeThumbs=
iped_libreOfficeTimeout=
iped_maxPdfExternalMemory=
iped_pdfThumbs=
iped_pdfTimeout=
iped_thumbSize=
iped_timeoutIncPerMB=
iped_enableExternalParsing=
iped_externalParsingMaxMem=
iped_minRawStringSize=
iped_numExternalParsers=
iped_parseCorruptedFiles=
iped_parseUnknownFiles=
iped_phoneParsersToUse=
iped_processImagesInPDFs=
iped_sortPDFChars=
iped_storeTextCacheOnDisk=
iped_timeOut=
iped_timeOutPerMB=
iped_computeFromThumbnail=
iped_minFileSize=
iped_skipHashDBFiles=
iped_phone_region=
```

# 🚀 Configuração do Docker Engine + NVIDIA Container Toolkit no WSL2

**Dica de ouro:** Se o instalador `.exe` do Docker Desktop estiver falhando ou apresentando problemas de inicialização no Windows, a solução definitiva é instalar o motor do Docker diretamente no **WSL2**. Isso garante um ambiente leve, sem interface gráfica desnecessária e com performance máxima para processamento de dados.

### 1. Preparar o Ambiente (PowerShell)
Antes de começar, garanta que o subsistema Linux está ativo e atualizado no Windows Host:

```powershell
wsl --install Ubuntu-24.04
```
*(Se já tiver a distribuição Ubuntu ativa, basta abrir o terminal dela pelo menu Iniciar).*

### 2. Instalar o Docker Engine (Terminal Ubuntu)
Execute a sequência de comandos abaixo dentro do terminal do Linux para configurar o repositório oficial e instalar o motor por linha de comando:

```bash
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release && \
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && \
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
sudo usermod -aG docker $USER && \
echo -e "\n# Start Docker daemon automatically\nif [ -z \"\$(pgrep -f dockerd)\" ]; then\n  sudo service docker start > /dev/null 2>&1\nfi" >> ~/.bashrc
```

### 3. Instalar o NVIDIA Container Toolkit (Terminal Ubuntu)
Com o Docker pronto, configure o suporte a GPU para permitir aceleração de hardware dentro dos seus containers:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list && \
\
sudo apt-get update && \
sudo apt-get install -y nvidia-container-toolkit && \
\
sudo nvidia-ctk runtime configure --runtime=docker && \
\
sudo service docker restart
newgrp docker
```

### 4. Validação da GPU no Container
Após o reinício do serviço, faça o teste para garantir que os containers estão enxergando a placa de vídeo do host:

```bash
docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
```

---

## 🛠️ Solução de Problemas

* **Permission Denied no socket:** Se receber erros de permissão ao rodar comandos do Docker sem `sudo`, adicione seu usuário ao grupo do Docker:
```bash
  sudo usermod -aG docker $USER && newgrp docker
  ```
* **GPU não encontrada no container:** O WSL2 espelha o hardware do Windows. Certifique-se de que o driver da NVIDIA no seu **Windows Host** está atualizado na versão mais recente.

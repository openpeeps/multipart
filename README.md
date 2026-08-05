<p align="center">
  <img src="https://github.com/openpeeps/multipart/blob/main/.github/logo.png" width="140px"><br>
  A simple multipart parser 👑 Written in Nim language
</p>

<p align="center">
  <code>nimble install multipart</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/multipart">API reference</a><br>
  <img src="https://github.com/openpeeps/multipart/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/multipart/workflows/docs/badge.svg" alt="Github Actions">
</p>

## Features
- Parses `multipart/form-data` content from HTTP requests — supports file uploads and text fields
- **Streaming parser** (`MultipartStreamer`) — feed body chunks as they arrive, no need to buffer the entire body in memory
- Synchronous (`parse`) and asynchronous (`parseAsync`) parsing APIs
- Progress callbacks for monitoring parsing progress (body start/done, file start/chunk/done)
- **Magic-number signature validation** via callbacks to accept or reject files on the fly
- Configurable size limits for files, text fields and the overall body (`MultipartSizeLimit`)
- Automatic cleanup of temporary files (`cleanup`, `cleanupInvalid`, `setupCleanupOnSignal`)

## Examples

### 1. Basic parsing
```nim
import multipart

let contentType = "multipart/form-data; boundary=----WebKitFormBoundaryABC123"

# Raw multipart/form-data body as a string or seq[byte]
let body = "...multipart body..." & readFile("photo.png")

var mp = initMultipart(contentType, tmpDir = getTempDir() / "uploads")
mp.parse(body)

for b in mp:
  case b.dataType
  of MultipartText:
    echo "Text field: ", b.fieldName, " = ", b.value
  of MultipartFile:
    echo "File: ", b.fieldName, " -> ", b.fileName, " (", b.fileType, ")"
    if fileExists(b.getPath):
      echo "Stored at: ", b.getPath

mp.cleanup()  # remove temporary files written during parsing
```

### 2. Progress tracking
```nim
var mp = initMultipart(contentType,
  progressCallback = proc(evt: MultipartProgress) =
    case evt.kind
    of progressBodyStart:
      echo "Parsing started. Total bytes: ", evt.totalBytes
    of progressFileStart:
      echo "File upload started: ", evt.fileName
    of progressFileChunk:
      echo "Wrote ", evt.bytesWritten, " bytes so far"
    of progressFileDone:
      echo "File upload completed: ", evt.fileName
    of progressBodyDone:
      echo "Parsing completed. Total bytes: ", evt.totalBytes
)

mp.progressChunkInterval = 64 * 1024  # fire a chunk event every 64KB, not every byte
mp.parse(body)
```

### 3. Magic-number (signature) validation
```nim
var mp = initMultipart(contentType, tmpDir = getTempDir() / "uploads")

# Accept only PNG files by validating their magic bytes
mp.fileSignatureCallback = proc(boundary: ptr Boundary, pos: int, c: ptr char): MultipartFileSigantureState =
  const pngSig = @[0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8, 0x0D'u8, 0x0A'u8, 0x1A'u8, 0x0A'u8]
  let b = byte(ord(c[]))
  if pos < pngSig.len and b == pngSig[pos]:
    if pos + 1 == pngSig.len: stateValidMagic
    else:                     stateMoreMagic
  else:
    stateInvalidMagic

mp.parse(body)

# Rejected files are moved to invalidBoundaries
for b in mp.invalidBoundaries:
  echo "Rejected: ", b.fileName

mp.cleanupInvalid()  # remove only the rejected temporary files
```

### 4. Size limits
```nim
var mp = initMultipart(contentType,
  sizeLimit = MultipartSizeLimit(
    maxFileSize: 10 * 1024 * 1024,  # 10 MB per file
    maxBodySize: 50 * 1024 * 1024,  # 50 MB total body
    maxFieldSize: 64 * 1024         # 64 KB per text field
  )
)

try:
  mp.parse(body)
except MultipartSizeLimitError as e:
  echo "Rejected: ", e.msg
```

### 5. Streaming parser
```nim
# Feed body chunks as they arrive from the network — no need to buffer the whole body
var ms = newMultipartStreamer(contentType, tmpDir = getTempDir() / "uploads",
                              bodySize = contentLength)

ms.feed(chunk1)
ms.feed(chunk2)
# ... feed more chunks as they arrive

if ms.isComplete():
  for b in ms.boundaries():
    echo b.fieldName, " -> ", b.fileName
  ms.cleanup()
```

### 6. Async parsing
```nim
import multipart, asyncdispatch

proc handleUpload() {.async.} =
  var mp = initMultipartRef(contentType)

  mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
    await ws.send($evt)  # stream progress to a WebSocket / SSE client

  await mp.parseAsync(body)
```

If you're looking for a full featured input validator you can use `openpeeps/bag` package to validate input data, forms, including `multipart/form-data`. Give a try https://github.com/openpeeps/bag


### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/multipart/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/multipart/fork)

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/pistachio/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. 🍕 [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright &copy; 2024 OpenPeeps & Contributors &mdash; All rights reserved.

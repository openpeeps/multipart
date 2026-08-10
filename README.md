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

Three runnable, self-contained examples live in [`examples/`](examples/). Run any
of them with `nim c -r examples/<file>.nim`. They cover the two parser styles —
**batch** (`Multipart.parse` / `parseAsync`) for bodies that are already in memory,
and **streaming** (`MultipartStreamer.feed`) for bodies that arrive incrementally
over the network.

### 1. Synchronous batch parser — [`examples/batch_parse.nim`](examples/batch_parse.nim)
The batch parser consumes a **complete in-memory body** in one call. Use it when
the whole body is already available — a microframework or event library that
buffered the request, a stored/loaded blob, or tests.

Covers: parsing from a `string`, a `seq[byte]`, or a zero-copy raw pointer;
iterating text fields and file parts; file spooling to a custom temp dir;
progress callbacks; magic-number signature validation; size limits; cleanup.

```nim
var mp = initMultipart(contentType,
  tmpDir = getTempDir() / "uploads",
  sizeLimit = MultipartSizeLimit(maxFileSize: 10 * 1024 * 1024))

mp.parse(body)                    # body is fully in memory
for b in mp:
  case b.dataType
  of MultipartText: echo b.fieldName, " = ", b.value
  of MultipartFile: echo b.fieldName, " -> ", b.getPath   # spooled to disk
mp.cleanup()                      # remove the temp files
```

### 2. Asynchronous batch parser — [`examples/batch_parse_async.nim`](examples/batch_parse_async.nim)
Same engine, but non-blocking: `MultipartRef` + `parseAsync` pushes progress to an
async callback (WebSocket / SSE) without blocking the event loop.

```nim
import multipart, asyncdispatch

var mp = initMultipartRef(contentType)
mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
  await ws.send($evt)             # stream progress to a WebSocket / SSE client
await mp.parseAsync(body)
```

### 3. Streaming parser — [`examples/stream_parser.nim`](examples/stream_parser.nim)
`MultipartStreamer.feed` consumes the body **incrementally** — feed it the chunks
that arrive from the network and it tracks boundary matches across feed
boundaries. The whole body never lives in memory. Use it for large uploads on
your own event loop.

Covers: feeding in network-sized chunks, byte-by-byte feeding, boundaries split
across feeds, progress events, size limits, and the closure-friendly
`MultipartStreamerRef`.

```nim
var ms = newMultipartStreamer(contentType, bodySize = contentLength)
ms.feed(chunk1)                   # feed chunks as they arrive
ms.feed(chunk2)
if ms.isComplete():
  for b in ms.boundaries():
    echo b.fieldName, " -> ", b.fileName
  ms.cleanup()
```

### When to use which
- **Batch (`parse` / `parseAsync`)** — the body is already in memory: small
  uploads, buffered frameworks, stored blobs. Simple, one call.
- **Streaming (`feed`)** — the body arrives incrementally over the network: large
  uploads. Only the headers plus a 64KB write buffer are held in memory.


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

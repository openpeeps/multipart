## examples/batch_parse_async.nim — Asynchronous batch parser (`parseAsync`).
##
## The async batch parser is the same `Multipart.parse` engine, but non-blocking:
## `MultipartRef` + `parseAsync` lets an `asyncProgressCallback` push progress to
## a WebSocket / SSE stream without blocking the event loop. Use it when the
## whole body is already in memory but you still want to stream progress or
## yield control to an async runtime.
##
## Run:  nim c -r examples/batch_parse_async.nim

import std/[os, asyncdispatch]
import ../src/multipart

const
  boundary = "----AsyncExampleBoundary7MA4YWxkTrZu0gW"
  contentType = "multipart/form-data; boundary=" & boundary

# ── Body fixture ──────────────────────────────────────────────────────────────

proc buildBody(): string =
  result = "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"title\"\r\n\r\n" &
           "My Document\r\n" &
           "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"attachment\"; filename=\"photo.bin\"\r\n" &
           "Content-Type: application/octet-stream\r\n\r\n" &
           "BINARYDATA" &
           "\r\n--" & boundary & "--\r\n"

# ── A fake WebSocket for the demo ─────────────────────────────────────────────
# Replace `FakeWs` with a real WebSocket/SSE connection: the progress callback
# is async precisely so `await ws.send(...)` can push without blocking.

type FakeWs = ref object
  events: seq[string]

proc send*(ws: FakeWs, s: string): Future[void] {.async.} =
  ws.events.add(s)

proc handleUpload(ws: FakeWs) {.async.} =
  echo "== parsing the buffered body asynchronously =="

  var mp = initMultipartRef(contentType,
    tmpDir = getTempDir() / "multipart_async_example",
    sizeLimit = MultipartSizeLimit(maxFileSize: 10 * 1024 * 1024))

  mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
    case evt.kind
    of progressBodyStart: await ws.send("body start (" & $evt.totalBytes & ")")
    of progressFileStart: await ws.send("file start: " & evt.fileName)
    of progressFileChunk: await ws.send("file chunk: " & $evt.bytesWritten)
    of progressFileDone:  await ws.send("file done: " & evt.fileName)
    of progressBodyDone:  await ws.send("body done (" & $evt.totalBytes & ")")

  mp.progressChunkInterval = 4   # tiny interval so chunk events show in this demo
  await mp.parseAsync(buildBody())

  echo "  parsed boundaries:"
  for b in mp:
    case b.dataType
    of MultipartText:
      echo "    text ", b.fieldName, " = ", b.value
    of MultipartFile:
      echo "    file ", b.fieldName, " -> ", b.fileName, " (", b.fileSize, " bytes)"
      echo "          spooled to ", b.getPath

  echo "  ws progress events:"
  for e in ws.events:
    echo "    ", e

  mp.cleanup()

proc main() {.async.} =
  await handleUpload(FakeWs(events: @[]))

waitFor main()

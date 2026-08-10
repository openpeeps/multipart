## examples/stream_parser.nim — Streaming parser (`MultipartStreamer.feed`).
##
## The streamer consumes the body INCREMENTALLY — feed it the chunks that arrive
## from the network and it tracks boundary matches across feed boundaries,
## spools file parts to disk, and enforces the same size limits / callbacks as
## the batch parser. The whole body never needs to live in memory.
##
## For an already-buffered body, see `batch_parse.nim` / `batch_parse_async.nim`.
##
## Run:  nim c -r examples/stream_parser.nim

import std/[os, strutils]
import ../src/multipart

const
  boundary = "----StreamExampleBoundary7MA4YWxkTrZu0gW"
  contentType = "multipart/form-data; boundary=" & boundary

# ── Body fixture ──────────────────────────────────────────────────────────────

proc buildBody(fileSize = 200_000): string =
  ## Text field + a large file (large enough to trigger progressFileChunk at the
  ## default 64KB interval).
  result = "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"note\"\r\n\r\n" &
           "Hello\r\n" &
           "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"blob\"; filename=\"blob.bin\"\r\n" &
           "Content-Type: application/octet-stream\r\n\r\n" &
           "A".repeat(fileSize) &
           "\r\n--" & boundary & "--\r\n"

proc dumpParts(ms: var MultipartStreamer) =
  for b in ms:
    case b.dataType
    of MultipartText:
      echo "    text ", b.fieldName, " = ", b.value
    of MultipartFile:
      echo "    file ", b.fieldName, " -> ", b.fileName, " (", b.fileSize, " bytes)"
  ms.cleanup()

proc feedNetwork(ms: var MultipartStreamer, body: string; chunk: int) =
  ## Simulate network reads: feed `body` in `chunk`-sized pieces.
  var pos = 0
  while pos < body.len:
    let n = min(chunk, body.len - pos)
    ms.feed(body[pos ..< pos + n])
    pos += n

# ── Demos ─────────────────────────────────────────────────────────────────────

proc demoChunked(chunk: int) =
  echo "== 1. feed in ", chunk, "-byte network chunks =="
  var ms = newMultipartStreamer(contentType,
    tmpDir = getTempDir() / "multipart_stream_example",
    bodySize = buildBody().len,      # known from Content-Length
    progressCallback = proc(evt: MultipartProgress) =
      case evt.kind
      of progressFileChunk: echo "    [progress] ", evt.fieldName, " chunk, ", evt.bytesWritten, " bytes"
      of progressBodyDone:  echo "    [progress] body done, ", evt.totalBytes, " bytes"
      else: discard)
  feedNetwork(ms, buildBody(), chunk)
  doAssert ms.isComplete()
  dumpParts(ms)

proc demoByteByByte() =
  echo "== 2. byte-by-byte (worst-case feed) =="
  var ms = newMultipartStreamer(contentType)
  for c in buildBody(fileSize = 8):
    ms.feed($c)
  doAssert ms.isComplete()
  echo "    parts: ", ms.len
  ms.cleanup()

proc demoSplitBoundary() =
  echo "== 3. closing boundary split across two feeds =="
  let body = buildBody(fileSize = 8)
  var ms = newMultipartStreamer(contentType)
  let at = body.find("\r\n--" & boundary & "--")
  doAssert at > 0
  ms.feed(body[0 ..< at])             # stop right before the closing marker
  echo "    complete after first feed? ", ms.isComplete()
  ms.feed(body[at ..< body.len])
  echo "    complete after second feed? ", ms.isComplete()
  echo "    text value: ", ms.boundaries()[0].value
  ms.cleanup()

proc demoSizeLimit() =
  echo "== 4. streaming maxFileSize -> MultipartSizeLimitError =="
  var ms = newMultipartStreamer(contentType,
    sizeLimit = MultipartSizeLimit(maxFileSize: 8))
  try:
    ms.feed(buildBody(fileSize = 200))
    echo "    unexpectedly accepted"
  except MultipartSizeLimitError as e:
    echo "    rejected: ", e.msg
  ms.cleanup()

proc demoRef() =
  echo "== 5. MultipartStreamerRef (captured in a closure) =="
  var ms = newMultipartStreamerRef(contentType, tmpDir = getTempDir() / "multipart_ref_example")
  # Typical wiring: ms[].feed is set as an HTTP body callback (onBodyData).
  proc feedAll(m: MultipartStreamerRef, body: string) =
    var pos = 0
    while pos < body.len:
      let n = min(9, body.len - pos)
      m[].feed(body[pos ..< pos + n])
      pos += n
  feedAll(ms, buildBody(fileSize = 32))
  doAssert ms.isComplete()
  echo "    parts: ", ms.len
  ms.cleanup()

proc main() =
  demoChunked(64)
  demoChunked(7)
  demoByteByByte()
  demoSplitBoundary()
  demoSizeLimit()
  demoRef()

main()

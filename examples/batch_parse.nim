## examples/batch_parse.nim — Synchronous batch parser (`Multipart.parse`).
##
## The batch parser consumes a COMPLETE multipart/form-data body that is already
## in memory — a `string`, a `seq[byte]`, or a raw pointer into another buffer
## (e.g. a microframework or event library that already buffered the request, or
## a stored/loaded blob). For bodies that arrive incrementally, see
## `stream_parser.nim`.
##
## Run:  nim c -r examples/batch_parse.nim

import std/[os, strutils]
import ../src/multipart

const
  boundary = "----BatchExampleBoundary7MA4YWxkTrZu0gW"
  contentType = "multipart/form-data; boundary=" & boundary

# ── Body fixture ──────────────────────────────────────────────────────────────

proc buildBody(): string =
  ## A multipart body with two text fields and one file field. The "PNG" magic
  ## bytes are real so the signature callback in `demoParseString` accepts it.
  result = "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"username\"\r\n\r\n" &
           "Alice\r\n" &
           "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"bio\"\r\n\r\n" &
           "multi-dash line\r\nsecond line\r\n" &
           "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"avatar\"; filename=\"me.png\"\r\n" &
           "Content-Type: image/png\r\n\r\n" &
           "\x89PNG\r\nfake-pixel-data" &
           "\r\n--" & boundary & "--\r\n"

# ── Callbacks ─────────────────────────────────────────────────────────────────

proc dumpProgress(evt: MultipartProgress) =
  case evt.kind
  of progressBodyStart: echo "    [progress] body start (total ", evt.totalBytes, " bytes)"
  of progressFileStart: echo "    [progress] file start: ", evt.fieldName, " = ", evt.fileName
  of progressFileChunk: echo "    [progress] file chunk: ", evt.bytesWritten, " bytes written"
  of progressFileDone:  echo "    [progress] file done: ", evt.fieldName
  of progressBodyDone:  echo "    [progress] body done (total ", evt.totalBytes, " bytes)"

proc pngSignature(boundary: ptr Boundary; pos: int; c: ptr char): MultipartFileSigantureState =
  ## Magic-number validation: accept only files starting with the PNG signature.
  const sig = [0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8]
  if pos < sig.len and byte(c[]) == sig[pos]:
    if pos + 1 == sig.len: stateValidMagic
    else:                  stateMoreMagic
  else:
    stateInvalidMagic

proc dumpParts(mp: Multipart) =
  for b in mp:
    case b.dataType
    of MultipartText:
      echo "    text  ", b.fieldName, " = ", b.value.escape()
    of MultipartFile:
      echo "    file  ", b.fieldName, " -> ", b.fileName,
           " (", b.fileType, ", ", b.fileSize, " bytes)"
      echo "          magic = ", b.getMagicNumbers()
      if fileExists(b.getPath):
        echo "          content = ", readFile(b.getPath).escape()
  if mp.invalidBoundaries.len > 0:
    echo "    rejected:"
    for b in mp.invalidBoundaries:
      echo "      - ", b.fileName

# ── Demos ─────────────────────────────────────────────────────────────────────

proc demoParseString() =
  echo "== 1. parse from a string =="
  var mp = initMultipart(contentType,
    tmpDir = getTempDir() / "multipart_example",
    sizeLimit = MultipartSizeLimit(
      maxFileSize: 10 * 1024 * 1024,
      maxBodySize: 20 * 1024 * 1024,
      maxFieldSize: 1 * 1024 * 1024),
    progressCallback = dumpProgress)
  mp.fileSignatureCallback = pngSignature
  mp.progressChunkInterval = 4     # tiny interval so chunk events show in this demo
  mp.parse(buildBody())
  dumpParts(mp)
  echo "    cleanup: removing temp files"
  mp.cleanup()

proc demoParseSeq() =
  echo "== 2. parse from a seq[byte] =="
  var body = buildBody()
  var bytes = newSeq[byte](body.len)
  if body.len > 0:
    copyMem(addr bytes[0], body.cstring, body.len)
  var mp = initMultipart(contentType)
  mp.parse(bytes)
  for b in mp:
    if b.dataType == MultipartText:
      echo "    text ", b.fieldName, " = ", b.value.escape()
  mp.cleanup()

proc demoParsePtr() =
  echo "== 3. zero-copy parse from a raw pointer =="
  let body = buildBody()
  # The pointer variant is for buffers owned elsewhere (libevent's request
  # buffer, a C shim, the HTTP parser's buffer) — no copy is made.
  var mp = initMultipart(contentType)
  mp.parse(cast[ptr UncheckedArray[byte]](unsafeAddr body[0]), body.len)
  for b in mp:
    if b.dataType == MultipartFile:
      echo "    file ", b.fieldName, " size = ", b.fileSize, " bytes"
  mp.cleanup()

proc demoSizeLimit() =
  echo "== 4. size limit -> MultipartSizeLimitError =="
  var mp = initMultipart(contentType,
    sizeLimit = MultipartSizeLimit(maxFieldSize: 4))  # "Alice" is 5 bytes
  try:
    mp.parse(buildBody())
    echo "    unexpectedly accepted"
  except MultipartSizeLimitError as e:
    echo "    rejected: ", e.msg
  mp.cleanup()

proc main() =
  demoParseString()
  demoParseSeq()
  demoParsePtr()
  demoSizeLimit()

main()

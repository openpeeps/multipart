import std/[os, unittest, strutils, sequtils, asyncdispatch]
import ../src/multipart

#
# Helpers
#

const boundary = "----WebKitFormBoundaryABC123"
const contentType = "multipart/form-data; boundary=" & boundary

proc crlf(s: string): string = s.replace("\n", "\r\n")

proc buildBody(parts: varargs[string]): string =
  ## Joins pre-built part strings and appends closing boundary
  for p in parts:
    result &= "--" & boundary & "\r\n"
    result &= p
  result &= "--" & boundary & "--\r\n"

proc textPart(name, value: string): string =
  "Content-Disposition: form-data; name=\"" & name & "\"\r\n\r\n" & value & "\r\n"

proc filePart(name, filename, mime, content: string): string =
  "Content-Disposition: form-data; name=\"" & name &
    "\"; filename=\"" & filename & "\"\r\n" &
    "Content-Type: " & mime & "\r\n\r\n" & content & "\r\n"

proc tmpDir(): string =
  getTempDir() / "multipart_tests"

#
# Suite: text fields
#

suite "Multipart text fields":

  test "single text field":
    let body = buildBody(textPart("username", "alice"))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check b.dataType == MultipartText
      check b.fieldName == "username"
      check b.value == "alice"

  test "multiple text fields":
    let body = buildBody(
      textPart("first", "John"),
      textPart("last",  "Doe"),
      textPart("age",   "30")
    )
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 3
    var names: seq[string]
    var values: seq[string]
    for b in mp:
      names.add b.fieldName
      values.add b.value
    check names == @["first", "last", "age"]
    check values == @["John", "Doe", "30"]

  test "empty text field value":
    let body = buildBody(textPart("empty", ""))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check b.value == ""

  test "text field with special characters":
    let body = buildBody(textPart("msg", "Hello, World! <script>alert(1)</script>"))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check b.value == "Hello, World! <script>alert(1)</script>"

  test "text field with multiline value":
    let body = buildBody(textPart("bio", "line1\r\nline2\r\nline3"))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check "line1" in b.value
      check "line3" in b.value

#
# Suite: file uploads
#

suite "Multipart file uploads":

  setup:
    discard existsOrCreateDir(tmpDir())

  test "single file upload":
    let content = "Hello from a test file!"
    let body = buildBody(filePart("upload", "hello.txt", "text/plain", content))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check b.dataType  == MultipartFile
      check b.fileName  == "hello.txt"
      check b.fileType  == "text/plain"
      check b.fieldName == "upload"
      check fileExists(b.getPath)
      let stored = readFile(b.getPath)
      check stored.split().len == content.split().len
      check stored == content

  test "file upload preserves binary content":
    # PNG-like magic bytes
    let content = "\x89PNG\r\n\x1a\nsome-pixel-data"
    let body = buildBody(filePart("img", "pixel.png", "image/png", content))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check fileExists(b.getPath)
      let stored = readFile(b.getPath)
      check stored == content

  test "mixed text and file":
    let body = buildBody(
      textPart("description", "my photo"),
      filePart("photo", "cat.jpg", "image/jpeg", "\xFF\xD8\xFF\xE0data")
    )
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 2
    var types: seq[MultipartDataType]
    for b in mp: types.add b.dataType
    check types == @[MultipartText, MultipartFile]

  test "multiple file uploads":
    let body = buildBody(
      filePart("f1", "a.txt", "text/plain",  "aaa"),
      filePart("f2", "b.txt", "text/plain",  "bbb"),
      filePart("f3", "c.txt", "text/plain",  "ccc")
    )
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 3
    var filenames: seq[string]
    for b in mp: filenames.add b.fileName
    check filenames == @["a.txt", "b.txt", "c.txt"]

#
# Suite: file callback
#

suite "Multipart file callback":

  setup:
    discard existsOrCreateDir(tmpDir())

  test "fileCallback receives bytes":
    var byteCount = 0
    proc cb(b: ptr Boundary, pos: int, c: ptr char): bool =
      inc byteCount
      true
    let body = buildBody(filePart("f", "x.bin", "application/octet-stream", "ABCDE"))
    var mp = initMultipart(contentType, fileCallback = cb, tmpDir = tmpDir())
    mp.parse(body)
    check byteCount > 0

  test "fileCallback rejection moves boundary to invalidBoundaries":
    var called = false
    proc cb(b: ptr Boundary, pos: int, c: ptr char): bool =
      called = true
      false  # reject immediately
    let body = buildBody(filePart("bad", "evil.exe", "application/octet-stream", "PAYLOAD"))
    var mp = initMultipart(contentType, fileCallback = cb, tmpDir = tmpDir())
    mp.parse(body)
    check called
    check mp.invalidBoundaries.len == 1
    check mp.invalidBoundaries[0].fileName == "evil.exe"

#
# Suite: magic-number / signature callback
#

suite "Multipart signature validation":

  setup:
    discard existsOrCreateDir(tmpDir())

  test "stateValidMagic keeps boundary":
    proc sigCb(b: ptr Boundary, pos: int, c: ptr char): MultipartFileSigantureState =
      stateValidMagic  # accept on first byte
    let body = buildBody(filePart("img", "ok.png", "image/png", "\x89PNGdata"))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.fileSignatureCallback = sigCb
    mp.parse(body)
    check mp.len == 1
    check mp.invalidBoundaries.len == 0

  test "stateInvalidMagic rejects boundary":
    proc sigCb(b: ptr Boundary, pos: int, c: ptr char): MultipartFileSigantureState =
      stateInvalidMagic
    let body = buildBody(filePart("img", "bad.png", "image/png", "NOTPNG"))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.fileSignatureCallback = sigCb
    mp.parse(body)
    check mp.invalidBoundaries.len == 1
    check mp.invalidBoundaries[0].fileName == "bad.png"

  test "stateMoreMagic collects bytes then validates":
    var calls = 0
    proc sigCb(b: ptr Boundary, pos: int, c: ptr char): MultipartFileSigantureState =
      inc calls
      if calls < 4: stateMoreMagic
      else:         stateValidMagic
    let body = buildBody(filePart("bin", "data.bin", "application/octet-stream", "ABCDEF"))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.fileSignatureCallback = sigCb
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check b.getMagicNumbers.len == 4

#
# Suite: edge cases
#

suite "Multipart edge cases":

  test "large text value":
    let big = 'x'.repeat(64 * 1024)
    let body = buildBody(textPart("blob", big))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check b.value.len == big.len

  test "filename with spaces":
    let body = buildBody(filePart("doc", "my document.pdf", "application/pdf", "pdfdata"))
    var mp = initMultipart(contentType, tmpDir = tmpDir())
    mp.parse(body)
    check mp.len == 1
    for b in mp:
      check b.fileName == "my document.pdf"

  test "getTempDir returns configured path":
    var mp = initMultipart(contentType, tmpDir = "/tmp/custom_test_dir")
    check mp.getTempDir == "/tmp/custom_test_dir"


suite "Multipart Parsing":

  setup:
    let profilePicturePath = "tests/assets/cs-black-000.png"
    let profilePicture = readFile(profilePicturePath)
    let profilePicSize = getFileSize(profilePicturePath)
    let header = "multipart/form-data; boundary=----WebKitFormBoundaryYAAP9BVpMwSByNYb"
    let prefixRaw = """
------WebKitFormBoundaryYAAP9BVpMwSByNYb

Content-Disposition: form-data; name="upload"; filename="document.txt"
Content-Type: text/plain

one two
three-four
-- five six ------
------
------WebKitFormBoundaryYAA04BVpMwSByNYb
Mikey filthy fingers
Dirty docs
Two socks
No jokes

------WebKitFormBoundaryYAAP9BVpMwSByNYb
Content-Disposition:form-data;name="firstname"
John

------WebKitFormBoundaryYAAP9BVpMwSByNYb
Content-Disposition:form-data;name="lastname"
Doe 2

------WebKitFormBoundaryYAAP9BVpMwSByNYb
Content-Disposition:form-data;name="email_address"
john.doe@example.com

------WebKitFormBoundaryYAAP9BVpMwSByNYb
Content-Disposition:form-data;name="whitespaces"
   

------WebKitFormBoundaryYAAP9BVpMwSByNYb
Content-Disposition: form-data; name="profile_picture"; filename="profile.png"
Content-Type: image/png
"""
    let prefix = prefixRaw.replace("\n", "\r\n") & "\r\n"
    let suffix = "\r\n------WebKitFormBoundaryYAAP9BVpMwSByNYb--\r\n"
    let body = prefix & profilePicture & suffix
    var mp: Multipart = initMultipart(header)

  test "Parse text fields":
    mp.parse(body)
    check mp.len == 6
    var textFields: seq[(string, string)]
    for b in mp:
      if b.dataType == MultipartText:
        textFields.add((b.fieldName, b.value))
    check textFields == @[
      ("firstname", "John"),
      ("lastname", "Doe 2"),
      ("email_address", "john.doe@example.com"),
      ("whitespaces", "   ")
    ]

  test "Parse file fields":
    mp.parse(body)
    var fileFields: seq[(string, string, string)]
    for b in mp:
      if b.dataType == MultipartFile:
        fileFields.add((b.fieldName, b.fileName, b.getPath))
    check fileFields.len == 2
    check fileFields[0][0] == "upload"
    check fileFields[0][1] == "document.txt"
    check fileFields[1][0] == "profile_picture"
    check fileFields[1][1] == "profile.png"

  test "Validate profile picture file":
    mp.parse(body)
    for b in mp:
      if b.fieldName == "profile_picture":
        check fileExists(b.getPath)
        check profilePicSize == getFileSize(b.getPath)
        check readFile(b.getPath).len == profilePicture.len

  test "Validate PNG signature for profile picture":
    mp.fileSignatureCallback = proc(boundary: ptr Boundary, pos: int, c: ptr char): MultipartFileSigantureState =
      if boundary[].fieldName == "profile_picture":
        const pngSig = @[0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8, 0x0D'u8, 0x0A'u8, 0x1A'u8, 0x0A'u8]
        let b = byte(ord(c[]))
        if pos < pngSig.len and b == pngSig[pos]:
          if pos + 1 == pngSig.len:
            return stateValidMagic
          else:
            return stateMoreMagic
        else:
          return stateInvalidMagic
      else:
        return stateValidMagic
    mp.parse(body)
    for b in mp:
      if b.fieldName == "profile_picture":
        check b.getMagicNumbers.len == 8

  test "Temporary directory path":
    let tmpPath = mp.getTempDir
    check tmpPath != ""
    for b in mp:
      if b.dataType == MultipartFile:
        check b.getPath.startsWith(tmpPath)


suite "Multipart Progress (sync)":

  test "all event kinds emitted for file upload":
    var kinds: seq[MultipartProgressKind]
    var mp = initMultipart(contentType, tmpDir = tmpDir(),
      progressCallback = proc(evt: MultipartProgress) =
        kinds.add(evt.kind)
    )
    mp.parse(buildBody(filePart("f", "test.txt", "text/plain", "Hello")))
    check progressBodyStart in kinds
    check progressFileStart in kinds
    check progressFileChunk in kinds
    check progressFileDone  in kinds
    check progressBodyDone  in kinds

  test "event order is correct":
    var kinds: seq[MultipartProgressKind]
    var mp = initMultipart(contentType, tmpDir = tmpDir(),
      progressCallback = proc(evt: MultipartProgress) =
        kinds.add(evt.kind)
    )
    mp.parse(buildBody(filePart("f", "test.txt", "text/plain", "Hello")))
    check kinds[0]  == progressBodyStart
    check kinds[1]  == progressFileStart
    check kinds[^2] == progressFileDone
    check kinds[^1] == progressBodyDone

  test "chunk count matches file size":
    var chunks: seq[MultipartProgress]
    var mp = initMultipart(contentType, tmpDir = tmpDir(),
      progressCallback = proc(evt: MultipartProgress) =
        if evt.kind == progressFileChunk:
          chunks.add(evt)
    )
    let content = "ABCDEFGHIJ"  # 10 bytes
    mp.parse(buildBody(filePart("f", "data.bin", "application/octet-stream", content)))
    check chunks.len == content.len
    check chunks[^1].bytesWritten == content.len.int64

  test "bytesWritten increments correctly":
    var written: seq[int64]
    var mp = initMultipart(contentType, tmpDir = tmpDir(),
      progressCallback = proc(evt: MultipartProgress) =
        if evt.kind == progressFileChunk:
          written.add(evt.bytesWritten)
    )
    mp.parse(buildBody(filePart("f", "data.bin", "application/octet-stream", "ABC")))
    check written == @[1'i64, 2'i64, 3'i64]

  test "totalBytes set correctly on body events":
    var startBytes, doneBytes: int64
    let body = buildBody(textPart("x", "y"))
    let expectedBytes = body.len.int64
    var mp = initMultipart(contentType, tmpDir = tmpDir(),
      progressCallback = proc(evt: MultipartProgress) =
        if evt.kind == progressBodyStart: startBytes = evt.totalBytes
        if evt.kind == progressBodyDone:  doneBytes  = evt.totalBytes
    )
    mp.parse(body)
    check startBytes == expectedBytes
    check doneBytes  == expectedBytes

  test "fileDone carries correct fieldName and fileName":
    var fileDone: MultipartProgress
    var mp = initMultipart(contentType, tmpDir = tmpDir(),
      progressCallback = proc(evt: MultipartProgress) =
        if evt.kind == progressFileDone: fileDone = evt
    )
    mp.parse(buildBody(filePart("photo", "cat.jpg", "image/jpeg", "JPEGDATA")))
    check fileDone.fieldName == "photo"
    check fileDone.fileName  == "cat.jpg"
    check fileDone.bytesWritten == "JPEGDATA".len.int64

  test "no progress events when no callback set":
    var mp = initMultipart(contentType, tmpDir = tmpDir())  # no progressCallback
    mp.parse(buildBody(textPart("x", "y")))
    check mp.len == 1  # parsed fine, no crash

  test "chunk interval suppresses intermediate chunks":
    var chunks = 0
    var mp = initMultipart(contentType, tmpDir = tmpDir(),
      progressCallback = proc(evt: MultipartProgress) =
        if evt.kind == progressFileChunk: inc chunks
    )
    mp.progressChunkInterval = 3  # emit every 3 bytes
    
    let content = "A".repeat(9)   # 9 bytes → expect 3 chunks
    mp.parse(buildBody(filePart("f", "data.bin", "application/octet-stream", content)))
    check chunks == 3

  test "multiple files each get fileStart and fileDone":
    var starts, dones: seq[string]
    var mp = initMultipart(contentType, tmpDir = tmpDir(),
      progressCallback = proc(evt: MultipartProgress) =
        if evt.kind == progressFileStart: starts.add(evt.fieldName)
        if evt.kind == progressFileDone:  dones.add(evt.fieldName)
    )
    mp.parse(buildBody(
      filePart("f1", "a.txt", "text/plain", "aaa"),
      filePart("f2", "b.txt", "text/plain", "bbb")
    ))
    check starts == @["f1", "f2"]
    check dones  == @["f1", "f2"]


suite "Multipart Progress (async)":

  test "all event kinds emitted for file upload":
    var kinds: seq[MultipartProgressKind]
    var mp = initMultipartRef(contentType, tmpDir = tmpDir())
    mp.asyncProgressCallback =
      proc(evt: MultipartProgress): Future[void] {.async.} =
        kinds.add(evt.kind)

    waitFor mp.parseAsync(buildBody(filePart("f", "test.txt", "text/plain", "Hello")))
    # the file is too small for the default chunk interval, so we expect only
    # start/done events for body and file
    check kinds == @[progressBodyStart, progressFileStart, progressFileDone, progressBodyDone]

  test "event order is correct":
    var kinds: seq[MultipartProgressKind]
    var mp = initMultipartRef(contentType, tmpDir = tmpDir())
    mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
      kinds.add(evt.kind)
    waitFor mp.parseAsync(buildBody(filePart("f", "test.txt", "text/plain", "Hello")))
    check kinds[0]  == progressBodyStart
    check kinds[1]  == progressFileStart
    check kinds[^2] == progressFileDone
    check kinds[^1] == progressBodyDone

  test "totalBytes set correctly on body events":
    var startBytes, doneBytes: int64
    let body = buildBody(textPart("x", "y"))
    let expectedBytes = body.len.int64
    var mp = initMultipartRef(contentType, tmpDir = tmpDir())
    mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
      if evt.kind == progressBodyStart: startBytes = evt.totalBytes
      if evt.kind == progressBodyDone:  doneBytes  = evt.totalBytes
    waitFor mp.parseAsync(body)
    check startBytes == expectedBytes
    check doneBytes  == expectedBytes

  test "async callback can await external work":
    var received: seq[MultipartProgressKind]
    var mp = initMultipartRef(contentType, tmpDir = tmpDir())
    mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
      await sleepAsync(1)
      received.add(evt.kind)
    waitFor mp.parseAsync(buildBody(filePart("f", "data.bin", "application/octet-stream", "ABC")))
    check progressBodyStart in received
    check progressBodyDone  in received

  test "sync callback ignored when async callback set":
    var syncCalled = false
    var asyncCalled = false
    var mp = initMultipartRef(contentType, tmpDir = tmpDir())
    mp.progressCallback = proc(evt: MultipartProgress) =
      syncCalled = true
    mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
      asyncCalled = true
    waitFor mp.parseAsync(buildBody(textPart("x", "y")))
    check asyncCalled
    check (not syncCalled)

  test "async progress callback on 10MB file":
    let largeContent = "A".repeat(5 * 1024 * 1024)  # 5MB of data
    var received: seq[MultipartProgressKind]
    var totalChunks = 0
    var mp = initMultipartRef(contentType, tmpDir = tmpDir())
    mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
      if evt.kind == progressFileChunk:
        inc totalChunks
      received.add(evt.kind)
      await sleepAsync(1)  # Simulate async work

    waitFor mp.parseAsync(buildBody(filePart("largeFile", "large.txt", "text/plain", largeContent)))

    check progressBodyStart in received
    check progressFileStart in received
    check progressFileChunk in received
    check progressFileDone in received
    check progressBodyDone in received

    # Validate the number of chunks emitted
    let expectedChunks = largeContent.len div mp.progressChunkInterval
    check totalChunks == expectedChunks
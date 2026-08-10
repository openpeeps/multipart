## tests/test_streamer.nim — Functional tests for the streaming multipart parser
## (`MultipartStreamer` / `MultipartStreamerRef`).
##
## The batch parser (`Multipart.parse`) has its own suite in test1.nim; this file
## covers the incremental `feed` API: single/incremental feeds, text fields, file
## uploads spooled to disk, boundary splits across feed boundaries, byte-by-byte
## feeding, CRLF and boundary-like data inside parts, large uploads, the ptr-based
## feed, preamble handling, size-limit enforcement, and equivalence with the batch
## parser.

import std/[os, unittest, strutils]
import ../src/multipart

const
  boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
  contentType = "multipart/form-data; boundary=" & boundary

# ── Helpers ───────────────────────────────────────────────────────────────────

proc makeTextBody(fields: openArray[(string, string)]): string =
  var parts: seq[string]
  for (name, value) in fields:
    parts.add("--" & boundary & "\r\n" &
              "Content-Disposition: form-data; name=\"" & name & "\"\r\n\r\n" &
              value & "\r\n")
  parts.add("--" & boundary & "--\r\n")
  result = parts.join("")

proc makeFileBody(fieldName, fileName, fileType, fileContent: string): string =
  result = "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"" & fieldName &
           "\"; filename=\"" & fileName & "\"\r\n" &
           "Content-Type: " & fileType & "\r\n\r\n" &
           fileContent & "\r\n" &
           "--" & boundary & "--\r\n"

proc makeMixedBody(textField: (string, string),
                   fileField: (string, string, string, string)): string =
  let (tName, tValue) = textField
  let (fName, fFileName, fFileType, fContent) = fileField
  result = "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"" & tName & "\"\r\n\r\n" &
           tValue & "\r\n" &
           "--" & boundary & "\r\n" &
           "Content-Disposition: form-data; name=\"" & fName &
           "\"; filename=\"" & fFileName & "\"\r\n" &
           "Content-Type: " & fFileType & "\r\n\r\n" &
           fContent & "\r\n" &
           "--" & boundary & "--\r\n"

proc feedInChunks(ms: var MultipartStreamer, body: string; chunkSize: int) =
  var pos = 0
  while pos < body.len:
    let endPos = min(pos + chunkSize, body.len)
    ms.feed(body[pos ..< endPos])
    pos = endPos

# ── Basic feeds ───────────────────────────────────────────────────────────────

test "single text field, single feed":
  let body = makeTextBody([("username", "Alice")])
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  doAssert ms.boundaries()[0].dataType == MultipartText
  doAssert ms.boundaries()[0].fieldName == "username"
  doAssert ms.boundaries()[0].value == "Alice"
  ms.cleanup()

test "single text field, incremental feeds":
  let body = makeTextBody([("username", "Alice")])
  var ms = newMultipartStreamer(contentType)
  feedInChunks(ms, body, max(1, body.len div 5))
  doAssert ms.isComplete()
  doAssert ms.len == 1
  doAssert ms.boundaries()[0].fieldName == "username"
  doAssert ms.boundaries()[0].value == "Alice"
  ms.cleanup()

test "multiple text fields":
  let body = makeTextBody([("name", "Bob"), ("email", "bob@example.com"), ("city", "NYC")])
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 3
  doAssert ms.boundaries()[0].fieldName == "name"
  doAssert ms.boundaries()[0].value == "Bob"
  doAssert ms.boundaries()[1].fieldName == "email"
  doAssert ms.boundaries()[1].value == "bob@example.com"
  doAssert ms.boundaries()[2].fieldName == "city"
  doAssert ms.boundaries()[2].value == "NYC"
  ms.cleanup()

# ── File uploads (spooled to disk) ────────────────────────────────────────────

test "file upload, single feed":
  let body = makeFileBody("upload", "test.txt", "text/plain", "Hello, file upload!")
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  let b = ms.boundaries()[0]
  doAssert b.dataType == MultipartFile
  doAssert b.fieldName == "upload"
  doAssert b.fileName == "test.txt"
  doAssert b.fileType == "text/plain"
  doAssert b.fileSize == 19
  doAssert fileExists(b.filePath)
  doAssert readFile(b.filePath) == "Hello, file upload!"
  ms.cleanup()

test "file upload, incremental feeds":
  let body = makeFileBody("upload", "test2.txt", "text/plain", "Hello, incremental file!")
  var ms = newMultipartStreamer(contentType)
  feedInChunks(ms, body, 5)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  let b = ms.boundaries()[0]
  doAssert b.fileSize == 24
  doAssert fileExists(b.filePath)
  doAssert readFile(b.filePath) == "Hello, incremental file!"
  ms.cleanup()

test "mixed text and file":
  let body = makeMixedBody(
    ("description", "My document"),
    ("file", "doc.txt", "text/plain", "Document content here")
  )
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 2
  doAssert ms.boundaries()[0].dataType == MultipartText
  doAssert ms.boundaries()[0].fieldName == "description"
  doAssert ms.boundaries()[0].value == "My document"
  doAssert ms.boundaries()[1].dataType == MultipartFile
  doAssert ms.boundaries()[1].fieldName == "file"
  doAssert ms.boundaries()[1].fileName == "doc.txt"
  doAssert fileExists(ms.boundaries()[1].filePath)
  doAssert readFile(ms.boundaries()[1].filePath) == "Document content here"
  ms.cleanup()

test "two files":
  let file1Content = "File One Content"
  let file2Content = "File Two Content"
  let body = "--" & boundary & "\r\n" &
             "Content-Disposition: form-data; name=\"file1\"; filename=\"a.txt\"\r\n" &
             "Content-Type: text/plain\r\n\r\n" &
             file1Content & "\r\n" &
             "--" & boundary & "\r\n" &
             "Content-Disposition: form-data; name=\"file2\"; filename=\"b.txt\"\r\n" &
             "Content-Type: text/plain\r\n\r\n" &
             file2Content & "\r\n" &
             "--" & boundary & "--\r\n"
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 2
  doAssert ms.boundaries()[0].fieldName == "file1"
  doAssert ms.boundaries()[0].fileName == "a.txt"
  doAssert fileExists(ms.boundaries()[0].filePath)
  doAssert readFile(ms.boundaries()[0].filePath) == file1Content
  doAssert ms.boundaries()[1].fieldName == "file2"
  doAssert ms.boundaries()[1].fileName == "b.txt"
  doAssert fileExists(ms.boundaries()[1].filePath)
  doAssert readFile(ms.boundaries()[1].filePath) == file2Content
  ms.cleanup()

# ── Boundary splits across feeds ──────────────────────────────────────────────

test "boundary split across feeds":
  let body = makeTextBody([("name", "SplitTest")])
  var ms = newMultipartStreamer(contentType)
  let endMarker = "\r\n--" & boundary & "--"
  let endMarkerPos = body.find(endMarker)
  doAssert endMarkerPos > 0
  let splitPos = endMarkerPos + 1  # split after the leading \r
  ms.feed(body[0 ..< splitPos])
  doAssert not ms.isComplete()
  ms.feed(body[splitPos ..< body.len])
  doAssert ms.isComplete()
  doAssert ms.len == 1
  doAssert ms.boundaries()[0].fieldName == "name"
  doAssert ms.boundaries()[0].value == "SplitTest"
  ms.cleanup()

test "boundary split exactly at the -- of the closing marker":
  let body = makeTextBody([("x", "y")])
  let firstPos = body.find("--" & boundary)
  doAssert firstPos >= 0
  let secondPos = body.find("--" & boundary, firstPos + boundary.len + 2)
  doAssert secondPos > firstPos
  var ms = newMultipartStreamer(contentType)
  ms.feed(body[0 ..< secondPos])
  doAssert not ms.isComplete()
  ms.feed(body[secondPos ..< body.len])
  doAssert ms.isComplete()
  doAssert ms.len == 1
  doAssert ms.boundaries()[0].fieldName == "x"
  doAssert ms.boundaries()[0].value == "y"
  ms.cleanup()

test "byte-by-byte feed":
  let body = makeTextBody([("key", "value")])
  var ms = newMultipartStreamer(contentType)
  for c in body:
    ms.feed($c)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  doAssert ms.boundaries()[0].fieldName == "key"
  doAssert ms.boundaries()[0].value == "value"
  ms.cleanup()

# ── Part data edge cases ──────────────────────────────────────────────────────

test "empty text field":
  let body = makeTextBody([("empty", "")])
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  doAssert ms.boundaries()[0].fieldName == "empty"
  doAssert ms.boundaries()[0].value == ""
  ms.cleanup()

test "text field with CRLF inside the value":
  let body = makeTextBody([("message", "Hello\r\nWorld")])
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.boundaries()[0].value == "Hello\r\nWorld"
  ms.cleanup()

test "file with CRLF in data":
  let fileContent = "line1\r\nline2\r\nline3"
  let body = makeFileBody("file", "test.bin", "application/octet-stream", fileContent)
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  let b = ms.boundaries()[0]
  doAssert fileExists(b.filePath)
  doAssert readFile(b.filePath) == fileContent
  ms.cleanup()

test "file with boundary-like data":
  let fileContent = "data\r\n--almost-boundary\r\nmore-data"
  let body = makeFileBody("file", "tricky.bin", "application/octet-stream", fileContent)
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  let b = ms.boundaries()[0]
  doAssert fileExists(b.filePath)
  doAssert readFile(b.filePath) == fileContent
  ms.cleanup()

test "large file streamed across feeds":
  let fileContent = "A".repeat(1024)
  let body = makeFileBody("bigfile", "big.dat", "application/octet-stream", fileContent)
  var ms = newMultipartStreamer(contentType)
  feedInChunks(ms, body, 64)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  let b = ms.boundaries()[0]
  doAssert b.fileSize == 1024
  doAssert fileExists(b.filePath)
  doAssert readFile(b.filePath).len == 1024
  ms.cleanup()

# ── feed variants ─────────────────────────────────────────────────────────────

test "feed with ptr UncheckedArray[byte]":
  let body = makeTextBody([("test", "ptr")])
  var ms = newMultipartStreamer(contentType)
  var data = newSeq[byte](body.len)
  copyMem(addr data[0], body.cstring, body.len)
  let ptrData = cast[ptr UncheckedArray[byte]](addr data[0])
  ms.feed(ptrData, body.len)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  doAssert ms.boundaries()[0].fieldName == "test"
  doAssert ms.boundaries()[0].value == "ptr"
  ms.cleanup()

# ── Completion state progression ──────────────────────────────────────────────

test "progressive isComplete":
  let body = makeTextBody([("key", "val")])
  var ms = newMultipartStreamer(contentType)
  ms.feed(body[0 ..< 10])
  doAssert not ms.isComplete()
  ms.feed(body[10 ..< body.len])
  doAssert ms.isComplete()
  ms.cleanup()

# ── Preamble ──────────────────────────────────────────────────────────────────

test "preamble before the first boundary is skipped":
  let preamble = "This is preamble data that should be ignored.\r\n"
  let body = preamble &
             "--" & boundary & "\r\n" &
             "Content-Disposition: form-data; name=\"field1\"\r\n\r\n" &
             "value1\r\n" &
             "--" & boundary & "--\r\n"
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()
  doAssert ms.len == 1
  doAssert ms.boundaries()[0].fieldName == "field1"
  doAssert ms.boundaries()[0].value == "value1"
  ms.cleanup()

# ── Size limits enforced mid-stream ───────────────────────────────────────────

test "maxFieldSize raises MultipartSizeLimitError":
  let body = makeTextBody([("field", repeat('A', 1000))])
  var ms = newMultipartStreamer(contentType,
    sizeLimit = MultipartSizeLimit(maxFieldSize: 100))
  expect MultipartSizeLimitError:
    ms.feed(body)
  ms.cleanup()

test "maxFileSize raises MultipartSizeLimitError while streaming":
  let body = makeFileBody("file", "big.bin", "application/octet-stream", repeat('B', 5000))
  var ms = newMultipartStreamer(contentType,
    sizeLimit = MultipartSizeLimit(maxFileSize: 1000))
  expect MultipartSizeLimitError:
    ms.feed(body)
  ms.cleanup()

test "maxBodySize raises MultipartSizeLimitError":
  let body = makeTextBody([("a", "x"), ("b", "y"), ("c", "z")])
  var ms = newMultipartStreamer(contentType,
    sizeLimit = MultipartSizeLimit(maxBodySize: 60))
  expect MultipartSizeLimitError:
    ms.feed(body)
  ms.cleanup()

# ── Equivalence with the batch parser ─────────────────────────────────────────

test "streamer matches the batch parser":
  let body = makeMixedBody(
    ("title", "Test Document"),
    ("attachment", "doc.pdf", "application/pdf", "PDF content here")
  )
  var mp = initMultipart(contentType)
  mp.parse(body)
  var ms = newMultipartStreamer(contentType)
  ms.feed(body)
  doAssert ms.isComplete()

  doAssert ms.len == mp.len
  var msItems: seq[Boundary]
  var mpItems: seq[Boundary]
  for b in ms: msItems.add(b)
  for b in mp: mpItems.add(b)
  for i in 0 ..< msItems.len:
    doAssert msItems[i].fieldName == mpItems[i].fieldName
    doAssert msItems[i].dataType == mpItems[i].dataType
    case msItems[i].dataType
    of MultipartText:
      doAssert msItems[i].value == mpItems[i].value
    of MultipartFile:
      doAssert msItems[i].fileName == mpItems[i].fileName
      doAssert msItems[i].fileType == mpItems[i].fileType
      doAssert readFile(msItems[i].filePath) == readFile(mpItems[i].filePath)

  ms.cleanup()
  mp.cleanup()

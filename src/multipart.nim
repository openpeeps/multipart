# A simple multipart parser for handling
# multipart/form-data content-type in Nim
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/supranim/multipart

## This module implements a simple multipart/form-data parser for Nim.
## 
## It allows you to parse multipart form data from HTTP requests, handling both file uploads and text fields.
## The parser processes the multipart content, extracts file data and text fields, and provides a structured
## representation of the parsed data through the `Multipart` type.
## 
## The parser also supports callbacks for handling file data as it's being parsed, which can be useful for on-the-fly
## validation or processing of uploaded files.
## 
## This package provides both synchronous and asynchronous parsing capabilities, making it suitable for various use cases,
## including web applications and APIs. The other Multipart parser is a streaming parser that can be used for large file
## uploads or when you want to process the data as it arrives.

import std/[os, streams, strutils, asyncdispatch,
            parseutils, options, oids, sequtils, macros]

when defined(posix):
  import std/posix

import pkg/checksums/md5

const
  MaxHeaderBufSize* = 8192
  MaxBoundaryLen* = 256
  MaxBoundaries* = 1000
  MaxHeaderLineLen* = 4096

type
  MultipartProgressKind* = enum
    progressBodyStart   ## fired once before parsing begins
    progressFileStart   ## fired when a new file boundary opens
    progressFileChunk   ## fired for every byte written to a file
    progressFileDone    ## fired when a file boundary closes
    progressBodyDone    ## fired once after parsing completes

  MultipartProgress* = object
    kind*: MultipartProgressKind
    fieldName*: string   ## which field this event belongs to
    fileName*: string    ## empty for text fields / body events
    bytesWritten*: int64 ## running total for the current file
    totalBytes*: int64   ## body size (set on progressBodyStart/Done)

  MultipartHeader* = enum
    ## Supported multipart headers
    contentDisposition = "content-disposition"
    contentType = "content-type"
  
  MultipartDataType* = enum
    ## Types of multipart data
    MultipartFile
    MultipartText

  MultipartFileSigantureState* = enum
    ## States for file magic-number signature validation
    stateInvalidMagic
    stateMoreMagic
    stateValidMagic

  MultipartHeaderTuple* = tuple[key: MultipartHeader, value: seq[(string, string)]]
    ## A tuple representing a multipart header

  MultipartFileCallback* = proc(boundary: ptr Boundary, pos: int, c: ptr char): bool {.closure.}
    ## A callback that runs while parsing a `MultipartFile` boundary
  
  MultipartProgressCallback* = proc(evt: MultipartProgress) {.closure.}
    ## sync variant — for non-async callers, fired every `progressChunkInterval` bytes

  MultipartAsyncProgressCallback* = proc(evt: MultipartProgress): Future[void] {.closure.}
    ## async variant — for async callers (WebSocket, SSE etc.)

  MultipartFileCallbackSignature* = proc(boundary: ptr Boundary, pos: int, c: ptr char): MultipartFileSigantureState {.closure.}
    ## A callback that runs while parsing a `MultipartFile` boundary to collect and validate magic

  MultipartTextCallback* = proc(boundary: ptr Boundary, data: ptr string): bool {.closure.}
    # A callback that returns data of a `MultipartText`.
    # 
    # This callback can be used for on-the-fly validation of
    # string-based data from input fields, and can determine whether the
    # boundary should be marked as invalid and skipped

  MultipartSizeLimitError* = object of CatchableError
    ## Raised when a size limit is exceeded

  MultipartSizeLimit* = object
    ## Configurable size limits for multipart parsing
    maxFileSize*: int64
      ## Maximum size for a single file upload in bytes (0 = unlimited)
    maxBodySize*: int64
      ## Maximum total body size in bytes (0 = unlimited)
    maxFieldSize*: int64
      ## Maximum size for a single text field value in bytes (0 = unlimited)

  MultipartConfigError* = object of CatchableError
    ## Raised when the multipart Content-Type is malformed

  # BoundaryEndCallback* = proc(boundary: Boundary): bool {.nimcall.}
  # A callback that runs after parsing a boundary
  BoundaryState* = enum
    boundaryInit
    boundaryAdded
      ## marks Boundary as added to `boundaries` sequenece
    boundaryRemoved
      ## can be set by external validators via `MultipartFileCallback`
      ## once invalidated, the `Boundary` will be moved to `invalidBoundaries`

  Boundary* = object
    state: BoundaryState
    fieldName*: string
    case dataType*: MultipartDataType
    of MultipartFile:
      fileId*, fileName*, fileType*, filePath*: string
      fileContent*: File
      fileSize*: int64
      # signature tracking for file magic-number validation
      signatureState*: MultipartFileSigantureState
      magicNumbers*: seq[byte]
    else:
      value*: string

  Multipart* = object
    tmpDirectory: string
      # Will use a temporary path to store files at
      # `getTempDir() / getMD5(getAppDir())`
    boundaryLine: string
      # Holds the boundary line retrieved from a
      # `Content-type` header
    fileCallback*: MultipartFileCallback
      ## A `MultipartFileCallback` that runs while in
      ## `MultipartFile` boundary 
    fileSignatureCallback*: MultipartFileCallbackSignature
      ## Collects magic numbers while writing a file to disk
      ## The callback must return one of 
      ## `MultipartFileSigantureState` states. Use `stateMoreMagic`
      ## to run `fileSignatureCallback` again for colelcting more bytes.
      ## 
      ## If the magic numbers are correct use `stateValidMagic`
      ## to stop the callback and continue writing the file.
      ## 
      ## `stateInvalidMagic` will mark the boundary as invalid,
      ## skip to `invalidBoundaries` and stops the callback.
      ## 
      ## `stateValidMagic` will continue writing the file on disk
      ## and stops the signature callback
    progressCallback*: MultipartProgressCallback
      ## An optional `MultipartProgressCallback` that fires inline during parsing.
      ## Called for every progress event
    asyncProgressCallback*: MultipartAsyncProgressCallback
      ## An optional `MultipartAsyncProgressCallback` that fires inline during parsing.
      ## Use this when you need to push progress events to an async stream (WebSocket, SSE)
      ## without blocking the event loop.
    progressChunkInterval*: int64
      ## How often (in bytes) to fire progressFileChunk.
      ## Default is every 64KB, set to 0 to emit every byte (not recommended)
    boundaries: seq[Boundary]
      # A sequence of Boundary objects
    invalidBoundaries*: seq[Boundary]
      # A sequence of removed boundaries
    totalBytesRead: int64
      # Total bytes read from the multipart body, used for enforcing `maxBodySize`
    bodySize: int64
      # Total size of the multipart body, set at the start of parsing
      # for progress reporting
    sizeLimit*: MultipartSizeLimit
      # Configurable size limits for multipart parsing
    fileWriteBuf: string
      # Internal: buffer for batched file writes
    fileWriteThreshold*: int
      # Flush file write buffer when it exceeds this many bytes (default 65536)

  MultipartRef* = ref Multipart
    ## Ref-counted wrapper for `Multipart`. Required for `parseAsync`
    ## since the async macro captures `mp` into a closure state machine
    ## and `var` params cannot be captured.

  MultipartInvalidHeader* = object of CatchableError

  StrReader = object
    data: string
    pos:  int

  ByteReader = object
    data: seq[byte]
    pos:  int

  ByteSliceReader = object
    data: ptr UncheckedArray[byte]
    len: int
    pos: int

proc readChar(r: var StrReader): char {.inline.} =
  result = r.data[r.pos]
  inc r.pos

proc readChar(r: var ByteReader): char {.inline.} =
  result = char(r.data[r.pos])
  inc r.pos

proc atEnd(r: StrReader): bool {.inline.} =
  r.pos >= r.data.len

proc atEnd(r: ByteReader): bool {.inline.} =
  r.pos >= r.data.len

proc peekStr(r: StrReader, n: int): string {.inline.} =
  let stop = min(r.pos + n, r.data.len)
  r.data[r.pos ..< stop]

proc peekStr(r: ByteReader, n: int): string {.inline.} =
  let stop = min(r.pos + n, r.data.len)
  result = newString(stop - r.pos)
  if result.len > 0:
    copyMem(addr result[0], addr r.data[r.pos], result.len)

proc readStr(r: var StrReader, n: int): string {.inline.} =
  let stop = min(r.pos + n, r.data.len)
  result = r.data[r.pos ..< stop]
  r.pos = stop

proc readStr(r: var ByteReader, n: int): string {.inline.} =
  let stop = min(r.pos + n, r.data.len)
  result = newString(stop - r.pos)
  if result.len > 0:
    copyMem(addr result[0], addr r.data[r.pos], result.len)
  r.pos = stop

proc close(r: var StrReader) {.inline.} =
  reset(r.data)

proc close(r: var ByteReader) {.inline.} =
  reset(r.data)

proc readChar(r: var ByteSliceReader): char {.inline.} =
  result = char(r.data[r.pos])
  inc r.pos

proc atEnd(r: ByteSliceReader): bool {.inline.} =
  r.pos >= r.len

proc peekStr(r: ByteSliceReader, n: int): string {.inline.} =
  let stop = min(r.pos + n, r.len)
  result = newString(stop - r.pos)
  if result.len > 0:
    copyMem(addr result[0], addr r.data[r.pos], result.len)

proc readStr(r: var ByteSliceReader, n: int): string {.inline.} =
  let stop = min(r.pos + n, r.len)
  result = newString(stop - r.pos)
  if result.len > 0:
    copyMem(addr result[0], addr r.data[r.pos], result.len)
  r.pos = stop

proc close(r: var ByteSliceReader) {.inline.} =
  discard

proc dataLen(r: StrReader): int {.inline.} = r.data.len
proc dataLen(r: ByteReader): int {.inline.} = r.data.len
proc dataLen(r: ByteSliceReader): int {.inline.} = r.len

proc parseHeader(line: string): MultipartHeaderTuple =
  # Parse a multipart header line into a MultipartHeaderTuple
  result.value = @[]
  var i = 0
  var key: string
  i = line.parseUntil(key, ':')
  inc(i) # skip :
  result.key = parseEnum[MultipartHeader](key.toLowerAscii)
  if result.key == contentType:
    i += line.skipWhitespace(i)
    result.value.add (line.substr(i), newStringOfCap(0))
  else:
    var v: string
    while i < line.len and line[i] notin Newlines:
      i += line.skipWhitespace(i)
      i += line.parseUntil(v, {';'}, i)
      if v == "form-data":
        setLen(v, 0) # skip form-data
      else:
        let kv = v.split('=', 1)
        add result.value, (kv[0], kv[1].unescape)
      inc(i)

template skipWhitespaces {.dirty.} =
  # Skip whitespace characters
  while true:
    case curr
    of Whitespace:
      curr = body.readChar()
    else: break

template skipNewlines {.dirty.} = 
  # Skip newline characters
  while true:
    case curr
    of '\r', '\n':
      curr = body.readChar
    else: break

const
  contentDispositionLen = len($contentDisposition)
  contentTypeLen = len($contentType)

template sendProgress(mp: var Multipart, evt: MultipartProgress) =
  # when set, this callback is fired inline during parsing to report progress events
  if mp.progressCallback != nil:
    mp.progressCallback(evt)

template sendProgressAsync(mp: MultipartRef, evt: MultipartProgress) =
  if mp.asyncProgressCallback != nil:
    await mp.asyncProgressCallback(evt)

template checkFileSizeLimit(someBoundary) {.dirty.} =
  if mp.sizeLimit.maxFileSize > 0 and
      someBoundary[].fileSize > mp.sizeLimit.maxFileSize:
    setLen(mp.fileWriteBuf, 0)
    someBoundary[].fileContent.close()
    removeFile(someBoundary[].filePath)
    someBoundary[].state = boundaryRemoved
    add mp.invalidBoundaries, someBoundary[]
    skipUntilNextBoundary = true
    raise newException(MultipartSizeLimitError,
      "File '" & someBoundary[].fileName & "' exceeds the maximum allowed size of " &
      $mp.sizeLimit.maxFileSize & " bytes")

template flushWriteBuf(someBoundary) {.dirty.} =
  if mp.fileWriteBuf.len > 0:
    write(someBoundary[].fileContent, mp.fileWriteBuf)
    setLen(mp.fileWriteBuf, 0)

template runFileCallback(progressSendTemplate, someBoundary) {.dirty.} =
  inc someBoundary[].fileSize   # track file size
  checkFileSizeLimit(someBoundary)

  # Emit per-chunk progress only when the interval condition is met
  if mp.progressChunkInterval <= 0 or (someBoundary[].fileSize mod mp.progressChunkInterval == 0):
    progressSendTemplate(mp, MultipartProgress(
      kind:         progressFileChunk,
      fieldName:    someBoundary[].fieldName,
      fileName:     someBoundary[].fileName,
      bytesWritten: someBoundary[].fileSize,
      totalBytes:   mp.bodySize
    ))

  # run file-signature callback (if provided) to collect/validate magic bytes.
  if mp.fileSignatureCallback != nil and someBoundary.signatureState != stateValidMagic:
    let sigState = mp.fileSignatureCallback(someBoundary, someBoundary.magicNumbers.len, curr.addr)
    case sigState
    of stateMoreMagic:
      # collect this byte for future introspection
      someBoundary.magicNumbers.add(byte(ord(curr)))
      someBoundary.signatureState = stateMoreMagic
    of stateValidMagic:
      someBoundary.magicNumbers.add(byte(ord(curr)))
      someBoundary.signatureState = stateValidMagic
    of stateInvalidMagic:
      # invalid signature: close and mark as removed, move to invalidBoundaries
      flushWriteBuf(someBoundary)
      someBoundary.fileContent.close()
      someBoundary.state = boundaryRemoved
      add mp.invalidBoundaries, someBoundary[]
      skipUntilNextBoundary = true
      break

  # if signature is valid (or no signature callback), run normal file callback if present.
  if mp.fileCallback != nil and someBoundary.signatureState != stateInvalidMagic:
    if mp.fileCallback(someBoundary, someBoundary.fileContent.getFilePos(), curr.addr):
      discard
    else:
      flushWriteBuf(someBoundary)
      someBoundary.fileContent.close()
      someBoundary.state = boundaryRemoved
      add mp.invalidBoundaries, someBoundary[]
      skipUntilNextBoundary = true
      break

template parseBoundary(progressSendTemplate) {.dirty.} =
  var currBoundary: string
  add currBoundary, curr
  curr = body.readChar()
  let len = len(boundary)
  add currBoundary, curr
  case curr:
  of '-':
    if body.peekStr(len).startsWith(boundary):
      add currBoundary, body.readStr(len)
      curr = body.readChar()
      skipWhitespaces()
      if body.peekStr(2) == "--":
        while not body.atEnd:
          discard body.readChar() # consume remaining chars
          break
      else:
        var headers: seq[MultipartHeaderTuple]
        while true:
          if "c" & body.peekStr(contentDispositionLen - 1).toLowerAscii == $contentDisposition:
            var heading: string
            add heading, curr
            add heading, body.readStr(contentDispositionLen)
            curr = body.readChar()
            while curr notin Newlines:
              if heading.len >= MaxHeaderLineLen:
                raise newException(MultipartSizeLimitError,
                  "Multipart header line exceeds max length")
              add heading, curr
              curr = body.readChar()
            add headers, parseHeader(heading)
            skipNewlines()
          elif "c" & body.peekStr(contentTypeLen - 1).toLowerAscii == $contentType:
            var heading: string
            add heading, curr
            add heading, body.readStr(contentTypeLen)
            curr = body.readChar()
            while curr notin Newlines:
              if heading.len >= MaxHeaderLineLen:
                raise newException(MultipartSizeLimitError,
                  "Multipart header line exceeds max length")
              add heading, curr
              curr = body.readChar()
            add headers, parseheader(heading)
            skipNewlines()
          else: break
        skipNewlines()
        if prevStreamBoundary.isSome:
          # close previous file boundary and run callback one last time with final file size
          flushWriteBuf(prevStreamBoundary.get)
          progressSendTemplate(mp, MultipartProgress(
            kind:         progressFileDone,
            fieldName:    prevStreamBoundary.get[].fieldName,
            fileName:     prevStreamBoundary.get[].fileName,
            bytesWritten: prevStreamBoundary.get[].fileSize
          ))
          prevStreamBoundary.get[].fileContent.close()
          prevStreamBoundary = none(ptr Boundary)
        
        # this is a file boundary — create a new Boundary with file metadata, open a
        # temp file for writing, and add it to the boundaries sequence
        if mp.boundaries.len >= MaxBoundaries:
          raise newException(MultipartSizeLimitError,
            "Exceeded maximum number of boundaries")
        if headers.len == 2:
          let fileId = $genOid()
          let filepath = mp.tmpDirectory / fileId
          add mp.boundaries,
            Boundary(
              dataType: MultipartFile,
              fileId: fileId,
              fieldName: headers[0].value[0][1],
              fileName: headers[0].value[1][1],
              fileType: headers[1].value[0][0],
              filePath: filepath,
              fileContent: open(filepath, fmWrite),
              # initialize signature tracking so callbacks can run as bytes are written
              signatureState: MultipartFileSigantureState.stateMoreMagic,
              magicNumbers: @[]
            )
          prevStreamBoundary = some(mp.boundaries[^1].addr)
          progressSendTemplate(mp, MultipartProgress(
            kind:      progressFileStart,
            fieldName: prevStreamBoundary.get[].fieldName,
            fileName:  prevStreamBoundary.get[].fileName
          ))
          mp.fileWriteBuf.add(curr)
          runFileCallback(progressSendTemplate, prevStreamBoundary.get)
        
        # this is a text field boundary — create a new Boundary with the field
        # name and an empty value, and add it to the boundaries sequence
        elif headers.len == 1:
          var inputBoundary =
            Boundary(
              dataType: MultipartText,
              fieldName: headers[0].value[0][1]
            )
          # add inputBoundary.value, curr
          add mp.boundaries, inputBoundary
          dec body.pos
      setLen(currBoundary, 0)
    else:
      if prevStreamBoundary.isSome:
        mp.fileWriteBuf.add(currBoundary)
        prevStreamBoundary.get[].fileSize += currBoundary.len.int64
        if mp.fileWriteBuf.len >= mp.fileWriteThreshold:
          flushWriteBuf(prevStreamBoundary.get)
          checkFileSizeLimit(prevStreamBoundary.get)
      else:
        add mp.boundaries[^1].value, currBoundary
      setLen(currBoundary, 0)
  else: discard
  if prevStreamBoundary.isSome:
    mp.fileWriteBuf.add(currBoundary)
    prevStreamBoundary.get[].fileSize += currBoundary.len.int64
    setLen(currBoundary, 0)

#
# Public API
#
proc cleanup*(mp: var Multipart|MultipartRef) =
  ## Removes all temporary files written to disk during parsing.
  ## Call this after you are done processing the boundaries.
  for b in mp.boundaries:
    if b.dataType == MultipartFile and b.filePath.len > 0:
      try: removeFile(b.filePath)
      except OSError: discard
  for b in mp.invalidBoundaries:
    if b.dataType == MultipartFile and b.filePath.len > 0:
      try: removeFile(b.filePath)
      except OSError: discard

proc cleanupInvalid*(mp: var Multipart|MultipartRef) =
  ## Removes only the temporary files for boundaries
  ## that were rejected (invalid signature / callback rejection).
  for b in mp.invalidBoundaries:
    if b.dataType == MultipartFile and b.filePath.len > 0:
      try: removeFile(b.filePath)
      except OSError: discard

proc initMultipart*(contentType: string,
    fileCallback: MultipartFileCallback = nil,
    progressCallback: MultipartProgressCallback = nil,
    sizeLimit = MultipartSizeLimit(),
    tmpDir = ""): Multipart =
  ## Initializes an instance of `Multipart`
  result.tmpDirectory =
    if tmpDir.len > 0: tmpDir
    else: getTempDir() / getMD5(getAppDir())
  result.boundaryLine = contentType
  result.fileCallback = fileCallback
  result.progressCallback = progressCallback
  result.fileWriteThreshold = 65536

proc initMultipartRef*(contentType: string,
    fileCallback: MultipartFileCallback = nil,
    progressCallback: MultipartProgressCallback = nil,
    sizeLimit = MultipartSizeLimit(),
    tmpDir = ""
): MultipartRef =
  ## Ref variant of `initMultipart`. Use when you need `parseAsync`.
  new(result)
  result[] = initMultipart(contentType,
    fileCallback = fileCallback,
    progressCallback = progressCallback,
    sizeLimit = sizeLimit,
    tmpDir = tmpDir)
  
  # running the progress on every byte can be a performance bottleneck for large files,
  # so we provide a configurable interval (default 64KB) for firing `progressFileChunk` events
  result[].progressChunkInterval = 64 * 1024

template parseImpl(progressSendTemplate: untyped) {.dirty.} =
  mp.bodySize = body.dataLen().int64
  if mp.sizeLimit.maxBodySize > 0 and mp.bodySize > mp.sizeLimit.maxBodySize:
    raise newException(MultipartSizeLimitError,
      "Request body (" & $body.dataLen() & " bytes) exceeds the maximum allowed size of " &
      $mp.sizeLimit.maxBodySize & " bytes")

  progressSendTemplate(mp, MultipartProgress(
    kind:       progressBodyStart,
    totalBytes: mp.bodySize
  ))

  var
    i = 0
    prevStreamBoundary: Option[ptr Boundary]
    multipartType: string
    multipartBoundary: string
  i += mp.boundaryLine.parseUntil(multipartType, {';'}, i)
  i += mp.boundaryLine.skipWhitespace(i)
  i += mp.boundaryLine.parseUntil(multipartBoundary, {'\c', '\l'}, i)
  let boundaryParts = multipartBoundary.split("boundary=")
  if boundaryParts.len < 2 or boundaryParts[1].len == 0:
    raise newException(MultipartConfigError,
      "Missing or empty boundary in Content-Type header")
  let boundary = boundaryParts[1]
  if boundary.len > MaxBoundaryLen:
    raise newException(MultipartConfigError,
      "Boundary exceeds maximum length of " & $MaxBoundaryLen & " bytes")
  discard existsOrCreateDir(mp.tmpDirectory)
  var
    skipUntilNextBoundary: bool
    currBoundary: ptr Boundary
    curr: char
  while not atEnd(body):
    if skipUntilNextBoundary:
      while curr != '-' and (body.atEnd == false):
        curr = body.readChar()
      parseBoundary(progressSendTemplate)
      skipUntilNextBoundary = false
    else:
      curr = body.readChar()
    case curr
    of Newlines:
      let maxLook = 4 + boundary.len
      let seq = curr & body.peekStr(maxLook)
      var idx = 0
      while idx < seq.len and seq[idx] in Newlines:
        inc idx
      let rem = if idx < seq.len: seq.substr(idx) else: ""
      if rem.startsWith("--" & boundary & "--"):
        break
      elif rem.startsWith("--" & boundary):
        continue
      else:
        if prevStreamBoundary.isSome:
          mp.fileWriteBuf.add(curr)
          runFileCallback(progressSendTemplate, prevStreamBoundary.get)
          if mp.fileWriteBuf.len >= mp.fileWriteThreshold:
            flushWriteBuf(prevStreamBoundary.get)
    of '-':
      parseBoundary(progressSendTemplate)
    else:
      currBoundary = addr(mp.boundaries[^1])
      if currBoundary != nil:
        case currBoundary[].dataType
        of MultipartFile:
          mp.fileWriteBuf.add(curr)
          runFileCallback(progressSendTemplate, currBoundary)
          if mp.fileWriteBuf.len >= mp.fileWriteThreshold:
            flushWriteBuf(currBoundary)
        of MultipartText:
          if mp.sizeLimit.maxFieldSize > 0 and
             currBoundary[].value.len >= mp.sizeLimit.maxFieldSize:
            currBoundary[].state = boundaryRemoved
            add mp.invalidBoundaries, currBoundary[]
            raise newException(MultipartSizeLimitError,
              "Text field '" & currBoundary[].fieldName &
              "' exceeds max field size of " & $mp.sizeLimit.maxFieldSize & " bytes")
          add currBoundary[].value, curr

  if prevStreamBoundary.isSome:
    flushWriteBuf(prevStreamBoundary.get)
    progressSendTemplate(mp, MultipartProgress(
      kind:         progressFileDone,
      fieldName:    prevStreamBoundary.get[].fieldName,
      fileName:     prevStreamBoundary.get[].fileName,
      bytesWritten: prevStreamBoundary.get[].fileSize
    ))
    prevStreamBoundary.get[].fileContent.close()
  body.close()
  progressSendTemplate(mp, MultipartProgress(
    kind:       progressBodyDone,
    totalBytes: mp.bodySize
  ))

proc parse*(mp: var Multipart, body: string, tmpDir = "") =
  ## Parse and return a `Multipart` instance synchronously from a multipart/form-data body string.
  ## 
  ## Raises `MultipartSizeLimitError` if any of the specified size limits are exceeded
  ## during parsing.
  var body = StrReader(data: body, pos: 0)
  parseImpl(sendProgress)

proc parse*(mp: var Multipart, body: seq[byte], tmpDir = "") =
  ## Parse a `Multipart` instance synchronously from a multipart/form-data body
  ## provided as raw bytes. Avoids the overhead of converting from a string.
  var body = ByteReader(data: body, pos: 0)
  parseImpl(sendProgress)

proc parseAsync*(mp: MultipartRef, body: string, tmpDir = "") {.async.} =
  ## Async variant of `parse`. Use when you need to push progress to
  ## a WebSocket or SSE stream without blocking the event loop.
  ## 
  ## Example:
  ##   ```nim
  ## mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
  ##   await ws.send($evt)   # push to WebSocket
  ## 
  ## mp.progressChunkInterval = 64 * 1024  # emit every 64KB, not every byte
  ## await mp.parseAsync(body)
  ##  ```
  var body = StrReader(data: body, pos: 0)
  parseImpl(sendProgressAsync)

proc parseAsync*(mp: MultipartRef, body: seq[byte], tmpDir = "") {.async.} =
  ## Async variant of `parse` for raw bytes input.
  var body = ByteReader(data: body, pos: 0)
  parseImpl(sendProgressAsync)

proc parse*(mp: var Multipart, data: ptr UncheckedArray[byte]; dataLen: int, tmpDir = "") =
  ## Zero-copy parse from a raw byte pointer.
  ## The pointer must remain valid for the duration of parsing
  ## (e.g. points into the HTTP parser buffer during a request handler).
  var body = ByteSliceReader(data: data, len: dataLen, pos: 0)
  parseImpl(sendProgress)

proc parseAsync*(mp: MultipartRef, data: ptr UncheckedArray[byte]; dataLen: int, tmpDir = "") {.async.} =
  ## Async zero-copy variant of `parse` from a raw byte pointer.
  var body = ByteSliceReader(data: data, len: dataLen, pos: 0)
  parseImpl(sendProgressAsync)

proc getTempDir*(mp: Multipart|MultipartRef): lent string =
  ## Returns the temporary directory path
  mp.tmpDirectory

proc getPath*(boundary: Boundary): lent string =
  ## Return the file path of a `Boundary` object
  ## if the boundary data type is `MultipartDataType`
  ## Check type using `getType`
  result = boundary.filePath

proc getMagicNumbers*(boundary: Boundary): lent seq[byte] =
  ## Returns the magic numbers collected while parsing the `boundary`
  result = boundary.magicNumbers

proc len*(mp: Multipart|MultipartRef): int =
  ## Returns the number of valid boundaries
  mp.boundaries.len

iterator items*(mp: Multipart|MultipartRef): Boundary =
  ## Iterate over available boundaries in
  ## the `Multipart` instance
  for b in mp.boundaries:
    yield b

# ── Streaming multipart parser ────────────────────────────────────────────────
#
# MultipartStreamer processes multipart/form-data incrementally via feed() calls.
# No need to buffer the entire body — works with onBodyData callbacks for
# true socket→multipart→disk streaming with minimal RAM.
#
# State machine:
#   sPreamble → match "--{boundary}" → sAfterBoundary → "\r\n" → sHeaders
#   sHeaders → "\r\n\r\n" → sData → match "\r\n--{boundary}" → sAfterBoundary
#   sAfterBoundary → "--" → sDone
#
# Boundary detection uses matchPos tracking against the boundary pattern.
# Partial matches spanning feed() calls are buffered in `pending` (max ~64 bytes).

type
  StreamerPhase = enum
    sPreamble       # Looking for first --boundary
    sHeaders        # Accumulating headers until \r\n\r\n
    sData           # Processing part data (file/text), scanning for \r\n--boundary
    sAfterBoundary  # After --boundary, checking \r\n (new part) or -- (end)
    sDone           # Parsing complete

  MultipartStreamer* = object
    ## Incremental multipart/form-data parser. Feed body data as it arrives
    ## from the network. No need to buffer the entire body.
    ##
    ## Usage:
    ##   var ms = newMultipartStreamer(contentType)
    ##   ms.feed(chunk1)
    ##   ms.feed(chunk2)
    ##   ...
    ##   if ms.isComplete():
    ##     for b in ms.boundaries(): ...
    ##     ms.cleanup()

    boundary: string
    dashBoundary: string       # "--{boundary}"
    crlfDashBoundary: string   # "\r\n--{boundary}"
    dashDashBoundary: string   # "--{boundary}--"

    phase: StreamerPhase

    # Boundary detection (sPreamble and sData)
    matchPos: int              # Current position in boundary pattern match
    pending: string            # Buffered bytes for potential boundary match
    isFirstBoundary: bool      # true while looking for the first --boundary

    # Header accumulation (sHeaders)
    headerBuf: string          # Accumulated header bytes, ends at \r\n\r\n

    # After-boundary checking (sAfterBoundary)
    afterBuf: string           # 2-byte buffer: \r\n or --

    # Current part tracking
    currentBoundaryIdx: int    # Index into mp.boundaries for current part (-1 = none)
    skipUntilNextBoundary: bool

    # Embedded Multipart for config (callbacks, limits, tmp dir) and results
    mp: Multipart

  MultipartStreamerRef* = ref MultipartStreamer
    ## Ref-counted wrapper for `MultipartStreamer`. Required when the
    ## streamer must be captured in closures (e.g. onBodyData callbacks).

proc newMultipartStreamer*(contentType: string,
    fileCallback: MultipartFileCallback = nil,
    fileSignatureCallback: MultipartFileCallbackSignature = nil,
    progressCallback: MultipartProgressCallback = nil,
    sizeLimit = MultipartSizeLimit(),
    tmpDir = "";
    bodySize = 0'i64): MultipartStreamer =
  ## Create a new streaming multipart parser.
  ## `contentType` is the full Content-Type header value
  ## (e.g. "multipart/form-data; boundary=----WebKitFormBoundaryXYZ").
  ## `bodySize` is the total body size if known (e.g. from Content-Length).
  result.mp.tmpDirectory =
    if tmpDir.len > 0: tmpDir
    else: getTempDir() / getMD5(getAppDir())
  result.mp.boundaryLine = contentType
  result.mp.fileCallback = fileCallback
  result.mp.fileSignatureCallback = fileSignatureCallback
  result.mp.progressCallback = progressCallback
  result.mp.sizeLimit = sizeLimit
  result.mp.fileWriteThreshold = 65536
  result.mp.progressChunkInterval = 64 * 1024
  result.mp.bodySize = bodySize
  result.phase = sPreamble
  result.isFirstBoundary = true
  result.currentBoundaryIdx = -1
  result.matchPos = 0

  # Extract boundary string from Content-Type
  var i = 0
  var multipartType: string
  var multipartBoundary: string
  i += contentType.parseUntil(multipartType, {';'}, i)
  i += contentType.skipWhitespace(i)
  i += contentType.parseUntil(multipartBoundary, {'\c', '\l'}, i)
  let boundaryParts = multipartBoundary.split("boundary=")
  if boundaryParts.len < 2 or boundaryParts[1].len == 0:
    raise newException(MultipartConfigError,
      "Missing or empty boundary in Content-Type header")
  result.boundary = boundaryParts[1]
  if result.boundary.len > MaxBoundaryLen:
    raise newException(MultipartConfigError,
      "Boundary exceeds maximum length of " & $MaxBoundaryLen & " bytes")
  result.dashBoundary = "--" & result.boundary
  result.crlfDashBoundary = "\r\n--" & result.boundary
  result.dashDashBoundary = "--" & result.boundary & "--"

  discard existsOrCreateDir(result.mp.tmpDirectory)

proc newMultipartStreamerRef*(contentType: string,
    fileCallback: MultipartFileCallback = nil,
    fileSignatureCallback: MultipartFileCallbackSignature = nil,
    progressCallback: MultipartProgressCallback = nil,
    sizeLimit = MultipartSizeLimit(),
    tmpDir = "";
    bodySize = 0'i64): MultipartStreamerRef =
  new(result)
  result[] = newMultipartStreamer(contentType,
    fileCallback = fileCallback,
    fileSignatureCallback = fileSignatureCallback,
    progressCallback = progressCallback,
    sizeLimit = sizeLimit,
    tmpDir = tmpDir,
    bodySize = bodySize)

# ── Internal helpers ──────────────────────────────────────────────────────────

template streamerFlushWriteBuf(ms: var MultipartStreamer, bIdx: int) =
  if ms.mp.fileWriteBuf.len > 0 and bIdx >= 0:
    write(ms.mp.boundaries[bIdx].fileContent, ms.mp.fileWriteBuf)
    setLen(ms.mp.fileWriteBuf, 0)

template streamerCheckFileSizeLimit(ms: var MultipartStreamer, bIdx: int) =
  if ms.mp.sizeLimit.maxFileSize > 0 and bIdx >= 0 and
      ms.mp.boundaries[bIdx].fileSize > ms.mp.sizeLimit.maxFileSize:
    setLen(ms.mp.fileWriteBuf, 0)
    ms.mp.boundaries[bIdx].fileContent.close()
    removeFile(ms.mp.boundaries[bIdx].filePath)
    ms.mp.boundaries[bIdx].state = boundaryRemoved
    add ms.mp.invalidBoundaries, ms.mp.boundaries[bIdx]
    ms.skipUntilNextBoundary = true
    raise newException(MultipartSizeLimitError,
      "File '" & ms.mp.boundaries[bIdx].fileName & "' exceeds the maximum allowed size of " &
      $ms.mp.sizeLimit.maxFileSize & " bytes")

template streamerSendProgress(ms: var MultipartStreamer, evt: MultipartProgress) =
  if ms.mp.progressCallback != nil:
    ms.mp.progressCallback(evt)

proc closeCurrentFile(ms: var MultipartStreamer) =
  if ms.currentBoundaryIdx >= 0 and
      ms.mp.boundaries[ms.currentBoundaryIdx].dataType == MultipartFile:
    streamerFlushWriteBuf(ms, ms.currentBoundaryIdx)
    streamerSendProgress(ms, MultipartProgress(
      kind:         progressFileDone,
      fieldName:    ms.mp.boundaries[ms.currentBoundaryIdx].fieldName,
      fileName:     ms.mp.boundaries[ms.currentBoundaryIdx].fileName,
      bytesWritten: ms.mp.boundaries[ms.currentBoundaryIdx].fileSize
    ))
    ms.mp.boundaries[ms.currentBoundaryIdx].fileContent.close()
    ms.currentBoundaryIdx = -1

proc writeDataByte(ms: var MultipartStreamer, c: char) =
  ## Write a data byte to the current boundary (file or text).
  ## Handles callbacks, progress, and size limits.
  if ms.skipUntilNextBoundary:
    return
  if ms.currentBoundaryIdx < 0:
    return
  let bIdx = ms.currentBoundaryIdx
  case ms.mp.boundaries[bIdx].dataType
  of MultipartFile:
    ms.mp.fileWriteBuf.add(c)
    inc ms.mp.boundaries[bIdx].fileSize
    streamerCheckFileSizeLimit(ms, bIdx)
    if ms.mp.fileWriteBuf.len >= ms.mp.fileWriteThreshold:
      streamerFlushWriteBuf(ms, bIdx)
    if ms.mp.progressChunkInterval <= 0 or
        (ms.mp.boundaries[bIdx].fileSize mod ms.mp.progressChunkInterval == 0):
      streamerSendProgress(ms, MultipartProgress(
        kind:         progressFileChunk,
        fieldName:    ms.mp.boundaries[bIdx].fieldName,
        fileName:     ms.mp.boundaries[bIdx].fileName,
        bytesWritten: ms.mp.boundaries[bIdx].fileSize,
        totalBytes:   ms.mp.bodySize
      ))
    if ms.mp.fileSignatureCallback != nil and
        ms.mp.boundaries[bIdx].signatureState != stateValidMagic:
      var curr = c
      let sigState = ms.mp.fileSignatureCallback(
        addr ms.mp.boundaries[bIdx],
        ms.mp.boundaries[bIdx].magicNumbers.len,
        curr.addr)
      case sigState
      of stateMoreMagic:
        ms.mp.boundaries[bIdx].magicNumbers.add(byte(ord(c)))
        ms.mp.boundaries[bIdx].signatureState = stateMoreMagic
      of stateValidMagic:
        ms.mp.boundaries[bIdx].magicNumbers.add(byte(ord(c)))
        ms.mp.boundaries[bIdx].signatureState = stateValidMagic
      of stateInvalidMagic:
        streamerFlushWriteBuf(ms, bIdx)
        ms.mp.boundaries[bIdx].fileContent.close()
        ms.mp.boundaries[bIdx].state = boundaryRemoved
        add ms.mp.invalidBoundaries, ms.mp.boundaries[bIdx]
        ms.skipUntilNextBoundary = true
        ms.currentBoundaryIdx = -1
        return
    if ms.mp.fileCallback != nil and
        ms.mp.boundaries[bIdx].signatureState != stateInvalidMagic:
      var curr = c
      if ms.mp.fileCallback(addr ms.mp.boundaries[bIdx],
          ms.mp.boundaries[bIdx].fileContent.getFilePos(), curr.addr):
        discard
      else:
        streamerFlushWriteBuf(ms, bIdx)
        ms.mp.boundaries[bIdx].fileContent.close()
        ms.mp.boundaries[bIdx].state = boundaryRemoved
        add ms.mp.invalidBoundaries, ms.mp.boundaries[bIdx]
        ms.skipUntilNextBoundary = true
        ms.currentBoundaryIdx = -1
        return
  of MultipartText:
    if ms.mp.sizeLimit.maxFieldSize > 0 and
       ms.mp.boundaries[bIdx].value.len >= ms.mp.sizeLimit.maxFieldSize:
      ms.mp.boundaries[bIdx].state = boundaryRemoved
      add ms.mp.invalidBoundaries, ms.mp.boundaries[bIdx]
      ms.skipUntilNextBoundary = true
      ms.currentBoundaryIdx = -1
      return
    add ms.mp.boundaries[bIdx].value, c

proc flushPendingAsData(ms: var MultipartStreamer) =
  for c in ms.pending:
    writeDataByte(ms, c)
  setLen(ms.pending, 0)

proc createPart(ms: var MultipartStreamer, headers: seq[MultipartHeaderTuple]) =
  ## Create a new Boundary from parsed headers and add it to mp.boundaries.
  if ms.mp.boundaries.len >= MaxBoundaries:
    raise newException(MultipartSizeLimitError,
      "Exceeded maximum number of boundaries")
  if headers.len == 2:
    let fileId = $genOid()
    let filepath = ms.mp.tmpDirectory / fileId
    discard existsOrCreateDir(ms.mp.tmpDirectory)
    add ms.mp.boundaries,
      Boundary(
        dataType: MultipartFile,
        fileId: fileId,
        fieldName: headers[0].value[0][1],
        fileName: headers[0].value[1][1],
        fileType: headers[1].value[0][0],
        filePath: filepath,
        fileContent: open(filepath, fmWrite),
        signatureState: MultipartFileSigantureState.stateMoreMagic,
        magicNumbers: @[]
      )
    ms.currentBoundaryIdx = ms.mp.boundaries.len - 1
    streamerSendProgress(ms, MultipartProgress(
      kind:      progressFileStart,
      fieldName: ms.mp.boundaries[ms.currentBoundaryIdx].fieldName,
      fileName:  ms.mp.boundaries[ms.currentBoundaryIdx].fileName
    ))
  elif headers.len == 1:
    add ms.mp.boundaries,
      Boundary(
        dataType: MultipartText,
        fieldName: headers[0].value[0][1]
      )
    ms.currentBoundaryIdx = ms.mp.boundaries.len - 1

proc parseStreamerHeaders(headerBuf: string): seq[MultipartHeaderTuple] =
  ## Parse multipart headers from an accumulated header buffer.
  ## The buffer contains lines between the boundary and \r\n\r\n,
  ## with the trailing \r\n\r\n already stripped by the caller.
  var headers: seq[MultipartHeaderTuple]
  for line in headerBuf.split("\r\n"):
    if line.len == 0:
      continue
    # Also handle bare \n (no \r) just in case
    for subline in line.split('\n'):
      if subline.len == 0:
        continue
      let colonPos = subline.find(':')
      if colonPos <= 0:
        continue
      let key = subline[0 ..< colonPos].toLowerAscii()
      if key == $contentDisposition or key == $contentType:
        headers.add(parseHeader(subline))
  result = headers

# ── feed() implementation ─────────────────────────────────────────────────────

proc feedImpl(ms: var MultipartStreamer, data: ptr UncheckedArray[byte], dataLen: int) =
  ## Core feed implementation. Processes data bytes through the state machine.
  if ms.phase == sDone:
    return

  # Fire progressBodyStart on first feed
  if ms.mp.totalBytesRead == 0 and dataLen > 0:
    streamerSendProgress(ms, MultipartProgress(
      kind:       progressBodyStart,
      totalBytes: ms.mp.bodySize
    ))

  var pos = 0
  while pos < dataLen and ms.phase != sDone:
    let c = char(data[pos])
    inc ms.mp.totalBytesRead

    # Check body size limit
    if ms.mp.sizeLimit.maxBodySize > 0 and
        ms.mp.totalBytesRead > ms.mp.sizeLimit.maxBodySize:
      raise newException(MultipartSizeLimitError,
        "Request body exceeds the maximum allowed size of " &
        $ms.mp.sizeLimit.maxBodySize & " bytes")

    case ms.phase
    of sPreamble:
      # Looking for the first --boundary
      # Match against dashBoundary = "--{boundary}"
      if ms.matchPos == 0:
        if c == ms.dashBoundary[0]:
          ms.matchPos = 1
          ms.pending.add(c)
        # else: skip preamble byte
      else:
        if c == ms.dashBoundary[ms.matchPos]:
          inc ms.matchPos
          ms.pending.add(c)
          if ms.matchPos == ms.dashBoundary.len:
            # First boundary matched!
            setLen(ms.pending, 0)
            ms.matchPos = 0
            ms.isFirstBoundary = false
            ms.phase = sAfterBoundary
        else:
          # Mismatch — not a boundary, skip preamble bytes
          setLen(ms.pending, 0)
          ms.matchPos = 0
          # Check if current byte starts a new match
          if c == ms.dashBoundary[0]:
            ms.matchPos = 1
            ms.pending.add(c)
      inc pos

    of sHeaders:
      # Accumulate header bytes until \r\n\r\n
      ms.headerBuf.add(c)
      let hlen = ms.headerBuf.len
      if ms.headerBuf.len >= MaxHeaderBufSize:
        raise newException(MultipartSizeLimitError,
          "Multipart headers exceed max buffer size")
      if hlen >= 4 and
          ms.headerBuf[hlen - 4] == '\r' and ms.headerBuf[hlen - 3] == '\n' and
          ms.headerBuf[hlen - 2] == '\r' and ms.headerBuf[hlen - 1] == '\n':
        # Headers complete — parse them and create a new part
        let headers = parseStreamerHeaders(ms.headerBuf[0 ..< hlen - 4])
        createPart(ms, headers)
        setLen(ms.headerBuf, 0)
        ms.phase = sData
      inc pos

    of sData:
      # Process part data, scanning for \r\n--boundary
      if ms.skipUntilNextBoundary:
        # Just scan for boundary pattern, don't write data
        if ms.matchPos == 0:
          if c == ms.crlfDashBoundary[0]:  # '\r'
            ms.matchPos = 1
            ms.pending.add(c)
        else:
          if c == ms.crlfDashBoundary[ms.matchPos]:
            inc ms.matchPos
            ms.pending.add(c)
            if ms.matchPos == ms.crlfDashBoundary.len:
              setLen(ms.pending, 0)
              ms.matchPos = 0
              ms.skipUntilNextBoundary = false
              closeCurrentFile(ms)
              ms.phase = sAfterBoundary
          else:
            # Mismatch — not a boundary, but we're skipping anyway
            setLen(ms.pending, 0)
            ms.matchPos = 0
            if c == ms.crlfDashBoundary[0]:
              ms.matchPos = 1
              ms.pending.add(c)
        inc pos
      else:
        # Normal data processing
        if ms.matchPos == 0:
          if c == ms.crlfDashBoundary[0]:  # '\r'
            ms.matchPos = 1
            ms.pending.add(c)
          else:
            writeDataByte(ms, c)
        else:
          if c == ms.crlfDashBoundary[ms.matchPos]:
            inc ms.matchPos
            ms.pending.add(c)
            if ms.matchPos == ms.crlfDashBoundary.len:
              # Full boundary match!
              # Close current file (if any) before transitioning
              setLen(ms.pending, 0)
              ms.matchPos = 0
              closeCurrentFile(ms)
              ms.phase = sAfterBoundary
          else:
            # Mismatch — buffered bytes are data, not a boundary
            flushPendingAsData(ms)
            ms.matchPos = 0
            # Re-check current byte
            if c == ms.crlfDashBoundary[0]:
              ms.matchPos = 1
              ms.pending.add(c)
            else:
              writeDataByte(ms, c)
        inc pos

    of sAfterBoundary:
      # After matching --boundary, check next 2 bytes: \r\n or --
      ms.afterBuf.add(c)
      if ms.afterBuf.len == 2:
        if ms.afterBuf == "\r\n":
          # New part starting
          setLen(ms.afterBuf, 0)
          ms.phase = sHeaders
        elif ms.afterBuf == "--":
          # Closing boundary
          setLen(ms.afterBuf, 0)
          ms.phase = sDone
          closeCurrentFile(ms)
          streamerSendProgress(ms, MultipartProgress(
            kind:       progressBodyDone,
            totalBytes: ms.mp.bodySize
          ))
        else:
          # Invalid per RFC — treat as data and resume sData
          for ch in ms.afterBuf:
            writeDataByte(ms, ch)
          setLen(ms.afterBuf, 0)
          ms.phase = sData
      inc pos

    of sDone:
      break

proc feed*(ms: var MultipartStreamer, data: openArray[byte]) =
  ## Feed a chunk of multipart body data. Can be called incrementally
  ## as data arrives from the network.
  if data.len == 0: return
  feedImpl(ms, cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), data.len)

proc feed*(ms: var MultipartStreamer, data: string) =
  ## Convenience overload for feeding string data.
  if data.len == 0: return
  feedImpl(ms, cast[ptr UncheckedArray[byte]](data.cstring), data.len)

proc feed*(ms: var MultipartStreamer, data: ptr UncheckedArray[byte]; dataLen: int) =
  ## Zero-copy feed from a raw byte pointer.
  if dataLen == 0: return
  feedImpl(ms, data, dataLen)

proc isComplete*(ms: MultipartStreamer): bool {.inline.} =
  ## Returns true when the closing --boundary-- has been seen.
  ms.phase == sDone

proc boundaries*(ms: MultipartStreamer): lent seq[Boundary] =
  ms.mp.boundaries

proc invalidBoundaries*(ms: MultipartStreamer): lent seq[Boundary] =
  ms.mp.invalidBoundaries

iterator items*(ms: MultipartStreamer): Boundary =
  for b in ms.mp.boundaries:
    yield b

proc cleanup*(ms: var MultipartStreamer) =
  ## Remove all temporary files written to disk during streaming parsing.
  ms.mp.cleanup()

proc cleanupInvalid*(ms: var MultipartStreamer) =
  ms.mp.cleanupInvalid()

proc len*(ms: MultipartStreamer): int =
  ms.mp.boundaries.len

proc getTempDir*(ms: MultipartStreamer): lent string =
  ms.mp.tmpDirectory

# ── MultipartStreamerRef overloads ─────────────────────────────────────────────

proc isComplete*(ms: MultipartStreamerRef): bool {.inline.} =
  ms[].isComplete()

proc boundaries*(ms: MultipartStreamerRef): lent seq[Boundary] =
  ms[].boundaries()

proc invalidBoundaries*(ms: MultipartStreamerRef): lent seq[Boundary] =
  ms[].invalidBoundaries()

iterator items*(ms: MultipartStreamerRef): Boundary =
  for b in ms[].mp.boundaries:
    yield b

proc cleanup*(ms: MultipartStreamerRef) =
  ms[].cleanup()

proc cleanupInvalid*(ms: MultipartStreamerRef) =
  ms[].cleanupInvalid()

proc len*(ms: MultipartStreamerRef): int =
  ms[].boundaries().len

when defined(posix):
  proc setupCleanupOnSignal*() =
    ## Register signal handlers for SIGINT and SIGTERM that clean up
    ## the default multipart temp directory on shutdown.
    ## Call at server startup to prevent temp file accumulation on crash.
    let tmpDir = getTempDir() / getMD5(getAppDir())
    proc handler(sig: cint) {.noconv.} =
      if dirExists(tmpDir):
        for path in walkDir(tmpDir):
          try: removeFile(path.path)
          except: discard
      quit(sig)
    signal(SIGINT, handler)
    signal(SIGTERM, handler)

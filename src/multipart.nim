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
## Features:
## - Parses multipart/form-data content from HTTP requests
## - Supports file uploads and text fields
## - Progress callbacks for monitoring parsing progress (body start/done, file start/chunk/done)
## - Configurable size limits for files and overall body
## - Callbacks for handling file data during parsing (magic number validation, custom processing)
## - Automatic cleanup of temporary files after processing

import std/[os, streams, strutils, asyncdispatch,
            parseutils, options, oids, sequtils, macros]

import pkg/checksums/md5

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

  MultipartRef* = ref Multipart
    ## Ref-counted wrapper for `Multipart`. Required for `parseAsync`
    ## since the async macro captures `mp` into a closure state machine
    ## and `var` params cannot be captured.

  MultipartInvalidHeader* = object of CatchableError

  StrReader = object
    data: string
    pos:  int

proc readChar(r: var StrReader): char {.inline.} =
  result = r.data[r.pos]
  inc r.pos

proc atEnd(r: StrReader): bool {.inline.} =
  r.pos >= r.data.len

proc peekStr(r: StrReader, n: int): string {.inline.} =
  let stop = min(r.pos + n, r.data.len)
  r.data[r.pos ..< stop]

proc readStr(r: var StrReader, n: int): string {.inline.} =
  let stop = min(r.pos + n, r.data.len)
  result = r.data[r.pos ..< stop]
  r.pos = stop

proc close(r: var StrReader) {.inline.} =
  # no resources to free, but we can clear the data for security
  reset(r.data)

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
    someBoundary[].fileContent.close()
    removeFile(someBoundary[].filePath)
    someBoundary[].state = boundaryRemoved
    add mp.invalidBoundaries, someBoundary[]
    skipUntilNextBoundary = true
    raise newException(MultipartSizeLimitError,
      "File '" & someBoundary[].fileName & "' exceeds the maximum allowed size of " &
      $mp.sizeLimit.maxFileSize & " bytes")

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
              add heading, curr
              curr = body.readChar()
            add headers, parseHeader(heading)
            # curr = body.readChar() # new line
            skipNewlines()
          elif "c" & body.peekStr(contentTypeLen - 1).toLowerAscii == $contentType:
            var heading: string
            add heading, curr
            add heading, body.readStr(contentTypeLen)
            curr = body.readChar()
            while curr notin Newlines:
              add heading, curr
              curr = body.readChar()
            add headers, parseheader(heading)
            skipNewlines()
          else: break
        skipNewlines()
        if prevStreamBoundary.isSome:
          # close previous file boundary and run callback one last time with final file size
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
          write(prevStreamBoundary.get[].fileContent, curr)
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
        write(prevStreamBoundary.get[].fileContent, currBoundary)
      else:
        add mp.boundaries[^1].value, currBoundary
      setLen(currBoundary, 0)
  else: discard
  if prevStreamBoundary.isSome:
    write(prevStreamBoundary.get[].fileContent, currBoundary)
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
    else: getTempDir() / getMD5(getAppDir()) # todo replace md5 with sha
  result.boundaryLine = contentType
  result.fileCallback = fileCallback
  result.progressCallback = progressCallback

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
  mp.bodySize = body.len.int64
  if mp.sizeLimit.maxBodySize > 0 and mp.bodySize > mp.sizeLimit.maxBodySize:
    raise newException(MultipartSizeLimitError,
      "Request body (" & $body.len & " bytes) exceeds the maximum allowed size of " &
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
  let boundary = multipartBoundary.split("boundary=")[1]
  discard existsOrCreateDir(mp.tmpDirectory)
  var
    body = StrReader(data: body, pos: 0)
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
          write(prevStreamBoundary.get[].fileContent, curr)
          runFileCallback(progressSendTemplate, prevStreamBoundary.get)
    of '-':
      parseBoundary(progressSendTemplate)
    else:
      currBoundary = addr(mp.boundaries[^1])
      if currBoundary != nil:
        case currBoundary[].dataType
        of MultipartFile:
          write(currBoundary[].fileContent, curr)
          runFileCallback(progressSendTemplate, currBoundary)
        of MultipartText:
          add currBoundary[].value, curr

  if prevStreamBoundary.isSome:
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
  parseImpl(sendProgress)

proc parseAsync*(mp: MultipartRef, body: string, tmpDir = "") {.async.} =
  ## Async variant of `parse`. Use when you need to push progress to
  ## a WebSocket or SSE stream without blocking the event loop.
  ## 
  ## Example:
  ## ```nim
  ## mp.asyncProgressCallback = proc(evt: MultipartProgress): Future[void] {.async.} =
  ##   await ws.send($evt)   # push to WebSocket
  ## 
  ## mp.progressChunkInterval = 64 * 1024  # emit every 64KB, not every byte
  ## await mp.parseAsync(body)
  ## ```
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

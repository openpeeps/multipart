# A simple multipart parser for handling
# multipart/form-data content-type in Nim
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/supranim/multipart

import std/[os, streams, strutils,
            parseutils, options, oids, sequtils]

import pkg/checksums/md5

type
  MultipartHeader* = enum
    contentDisposition = "content-disposition"
    contentType = "content-type"
  
  MultipartDataType* = enum
    MultipartFile
    MultipartText

  MultipartFileSigantureState* = enum
    stateInvalidMagic
    stateMoreMagic
    stateValidMagic

  MultipartHeaderTuple* = tuple[key: MultipartHeader, value: seq[(string, string)]]

  MultipartFileCallback* =
    proc(boundary: ptr Boundary, pos: int, c: ptr char): bool {.closure.}
    ## A callback that runs while parsing a `MultipartFile` boundary
  
  MultipartFileCallbackSignature* = proc(boundary: ptr Boundary, pos: int, c: ptr char): MultipartFileSigantureState {.closure.}
    ## A callback to collect magic numbers signature
    ## while writing the temporary file

  MultipartTextCallback* = proc(boundary: ptr Boundary, data: ptr string): bool {.closure.}
    ## A callback that returns data of a `MultipartText`.
    ## 
    ## This callback can be used for on-the-fly validation of
    ## string-based data from input fields

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
    else:
      value*: string

  Multipart* = object
    tmpDirectory: string
      # Will use a temporary path to store files at
      # `getTempDir() / getMD5(getAppDir())`
    boundaryLine: string
      # Holds the boundary line retrieved from a
      # `Content-type` header
    fileCallback*: ptr MultipartFileCallback
      ## A `MultipartFileCallback` that runs while in
      ## `MultipartFile` boundary 
    fileSignatureCallback*: ptr MultipartFileCallbackSignature
      ## Collects magic numbers that required for verifying
      ## the file type. The callback must return one of 
      ## `MultipartFileSigantureState` states. Use `stateMoreMagic`
      ## to run `fileSignatureCallback` again for colelcting more bytes.
      ## 
      ## If the magic numbers are correct use `stateValidMagic`
      ## to stop the callback and continue writing the file.
      ## 
      ## `stateInvalidMagic` will mark the boundary as invalid,
      ## skip it to `invalidBoundaries` and stops the callback.
      ## 
      ## `stateValidMagic` will continue writing the file on disk
      ## and stops the signature callback
    boundaries: seq[Boundary]
      # A sequence of Boundary objects
    invalidBoundaries*: seq[Boundary]
      # A sequence of removed boundaries

  MultipartInvalidHeader* = object of CatchableError

proc parseHeader(line: string): MultipartHeaderTuple =
  result.value = @[]
  var key: string
  var i = 0
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

template skipWhitespaces =
  while true:
    case curr
    of Whitespace:
      curr = body.readChar()
    else: break

template skipNewlines = 
  while true:
    case curr
    of '\r', '\n':
      curr = body.readChar
    else: break

const
  contentDispositionLen = len($contentDisposition)
  contentTypeLen = len($contentType)

template runFileCallback(someBoundary) {.dirty.} =
  if mp.fileCallback != nil:
    if mp.fileCallback[](someBoundary,
      someBoundary.fileContent.getFilePos(), curr.addr):
        discard
    else:
      someBoundary.fileContent.close()
      skipUntilNextBoundary = true
      break

template parseBoundary {.dirty.} =
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
          prevStreamBoundary.get[].fileContent.close()
          prevStreamBoundary = none(ptr Boundary)
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
              fileContent: open(filepath, fmWrite)
            )
          prevStreamBoundary = some(mp.boundaries[^1].addr)
          write(prevStreamBoundary.get[].fileContent, curr)
          runFileCallback(prevStreamBoundary.get)
        elif headers.len == 1:
          var inputBoundary =
            Boundary(
              dataType: MultipartText,
              fieldName: headers[0].value[0][1]
            )
          add inputBoundary.value, curr
          add mp.boundaries, inputBoundary
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
proc initMultipart*(contentType: string,
    fileCallback: ptr MultipartFileCallback = nil,
    tmpDir = ""
): Multipart =
  ## Initializes an instance of `Multipart`
  result.tmpDirectory =
    if tmpDir.len > 0: tmpDir
    else: getTempDir() / getMD5(getAppDir())
  result.boundaryLine = contentType
  if fileCallback != nil:
    result.fileCallback = fileCallback

proc parse*(mp: var Multipart, body: sink string, tmpDir = "") =
  ## Parse and return a `Multipart` instance
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
    body = newStringStream(body)
    skipUntilNextBoundary: bool
    currBoundary: ptr Boundary
    curr: char
  while not atEnd(body):
    if skipUntilNextBoundary:
      while curr != '-' and (body.atEnd == false):
        curr = body.readChar()
      parseBoundary()
      skipUntilNextBoundary = false
    else:
      curr = body.readChar()
    
    # main parsing logic
    case curr
    of Newlines:
      # check if next chars are the end of boundary
      if body.peekStr(2) == "--" and body.peekStr(4 + boundary.len).endsWith(boundary & "--"):
        break # end of multipart data
      elif prevStreamBoundary.isSome:
        write(prevStreamBoundary.get[].fileContent, curr)
        runFileCallback(prevStreamBoundary.get)
    of '-':
      parseBoundary()
    else:
      currBoundary = addr(mp.boundaries[^1])
      if currBoundary != nil:
        case currBoundary[].dataType
        of MultipartFile:
          write(currBoundary[].fileContent, curr)
          runFileCallback(currBoundary)
        of MultipartText:
          add currBoundary[].value, curr
  if prevStreamBoundary.isSome:
    prevStreamBoundary.get[].fileContent.close()
  body.close()
  

proc getTempDir*(mp: Multipart): string =
  ## Returns the temporary directory path
  mp.tmpDirectory

proc getPath*(boundary: Boundary): string =
  ## Return the file path of a `Boundary` object
  ## if the boundary data type is `MultipartDataType`
  ## Check type using `getType`
  result = boundary.filePath

proc getMagicNumbers*(boundary: Boundary): seq[byte] =
  ## Returns the magic numbers collected while parsing the `boundary`

proc len*(mp: Multipart): int =
  ## Returns the number of valid boundaries
  mp.boundaries.len

iterator items*(mp: Multipart): Boundary =
  ## Iterate over available boundaries in
  ## the `Multipart` instance
  for b in mp.boundaries:
    yield b

## tests/test_security.nim — Security regression tests for the multipart parser.
##
## These pin the fixes for remote-crash (IndexDefect) findings:
##   1. Malformed part headers must raise a CatchableError, never a Defect
##      (an uncaught Defect aborts the host HTTP server).
##   2. Bodies without a leading boundary (preamble / garbage) must not crash.
##   3. Uploaded temp files must be private (0600) and symlink-safe.

import std/[unittest, os, strutils]
import ../src/multipart

const
  boundary = "----SecBoundary"
  contentType = "multipart/form-data; boundary=" & boundary

proc classifyStream(body: string): string =
  var ms = newMultipartStreamer(contentType)
  try:
    ms.feed(body)
    result = "ok parts=" & $ms.len
  except MultipartSizeLimitError:
    result = "size-limit"
  except MultipartInvalidHeader:
    result = "invalid-header"
  except MultipartConfigError:
    result = "config-error"
  except Defect as e:
    result = "DEFECT: " & e.msg
  except CatchableError as e:
    result = "catchable: " & e.msg
  try: ms.cleanup()
  except: discard

proc classifyBuffered(body: string): string =
  var mp = initMultipart(contentType)
  try:
    mp.parse(body)
    result = "ok parts=" & $mp.len
  except MultipartSizeLimitError:
    result = "size-limit"
  except MultipartInvalidHeader:
    result = "invalid-header"
  except MultipartConfigError:
    result = "config-error"
  except Defect as e:
    result = "DEFECT: " & e.msg
  except CatchableError as e:
    result = "catchable: " & e.msg
  try: mp.cleanup()
  except: discard

suite "multipart parser never raises a Defect on hostile input":

  test "streamer: CD parameter missing '=' (form-data; name)":
    let r = classifyStream("--" & boundary & "\r\nContent-Disposition: form-data; name\r\n\r\nv\r\n" &
                           "--" & boundary & "--\r\n")
    check not r.startsWith("DEFECT")

  test "streamer: CD with no parameters":
    let r = classifyStream("--" & boundary & "\r\nContent-Disposition: form-data\r\n\r\nv\r\n" &
                           "--" & boundary & "--\r\n")
    check not r.startsWith("DEFECT")

  test "streamer: file part missing filename":
    let r = classifyStream("--" & boundary & "\r\nContent-Disposition: form-data; name=\"f\"\r\n" &
                           "Content-Type: text/plain\r\n\r\ndata\r\n--" & boundary & "--\r\n")
    check not r.startsWith("DEFECT")

  test "streamer: file part missing name":
    let r = classifyStream("--" & boundary & "\r\nContent-Disposition: form-data; filename=\"f.txt\"\r\n" &
                           "Content-Type: text/plain\r\n\r\ndata\r\n--" & boundary & "--\r\n")
    check not r.startsWith("DEFECT")

  test "buffered: CD parameter missing '='":
    let r = classifyBuffered("--" & boundary & "\r\nContent-Disposition: form-data; name\r\n\r\nv\r\n" &
                             "--" & boundary & "--\r\n")
    check not r.startsWith("DEFECT")

  test "buffered: file part missing filename":
    let r = classifyBuffered("--" & boundary & "\r\nContent-Disposition: form-data; name=\"f\"\r\n" &
                             "Content-Type: text/plain\r\n\r\ndata\r\n--" & boundary & "--\r\n")
    check not r.startsWith("DEFECT")

suite "buffered parser survives bodies without a leading boundary":

  test "preamble before first boundary":
    let r = classifyBuffered("PREAMBLE\r\n--" & boundary & "\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n" &
                             "--" & boundary & "--\r\n")
    check not r.startsWith("DEFECT")

  test "pure garbage, no boundary":
    let r = classifyBuffered("garbage-no-boundary-at-all")
    check not r.startsWith("DEFECT")

suite "well-formed multipart still parses (no false positives)":

  test "streamer parses valid text + file parts":
    var ms = newMultipartStreamer(contentType)
    let body = "--" & boundary & "\r\n" &
               "Content-Disposition: form-data; name=\"field\"\r\n\r\n" &
               "value\r\n" &
               "--" & boundary & "\r\n" &
               "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" &
               "Content-Type: text/plain\r\n\r\n" &
               "hello\r\n" &
               "--" & boundary & "--\r\n"
    ms.feed(body)
    check ms.isComplete()
    check ms.len == 2
    check ms.boundaries()[0].dataType == MultipartText
    check ms.boundaries()[0].fieldName == "field"
    check ms.boundaries()[0].value == "value"
    check ms.boundaries()[1].dataType == MultipartFile
    check ms.boundaries()[1].fileName == "a.txt"
    check readFile(ms.boundaries()[1].filePath) == "hello"
    ms.cleanup()

when not defined(windows):
  suite "temp file permissions":

    test "uploaded file is not world/group readable":
      let tmp = getTempDir() / "multipart_sec_" & $getCurrentProcessId()
      createDir(tmp)
      defer: removeDir(tmp)
      var ms = newMultipartStreamer(contentType, tmpDir = tmp)
      ms.feed("--" & boundary & "\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\n" &
              "Content-Type: text/plain\r\n\r\nSECRET\r\n--" & boundary & "--\r\n")
      for b in ms.boundaries():
        if b.dataType == MultipartFile:
          let mode = getFilePermissions(b.filePath)
          check fpOthersRead notin mode
          check fpGroupRead notin mode
      ms.cleanup()

    test "does not follow a pre-existing symlink at the target path":
      # We cannot predict the genOid filename, so instead verify that creating a
      # file at a known path through openPrivateFile refuses to follow a symlink.
      let tmp = getTempDir() / "multipart_sec_sym_" & $getCurrentProcessId()
      createDir(tmp)
      defer: removeDir(tmp)
      let target = getTempDir() / "multipart_sec_victim_" & $getCurrentProcessId()
      writeFile(target, "DO-NOT-OVERWRITE")
      defer: removeFile(target)
      createSymlink(target, tmp / "sneaky.txt")
      var refused = false
      try:
        let f = openPrivateFile(tmp / "sneaky.txt")
        f.close()
      except IOError:
        refused = true
      check refused
      check readFile(target) == "DO-NOT-OVERWRITE"

import std/[os, unittest, strutils, sequtils]
import multipart

test "can parse":
  let
    header = "multipart/form-data; boundary=----WebKitFormBoundaryYAAP9BVpMwSByNYb"
    body = """
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
Content-Disposition: form-data; name="firstname"

Johhny Four Fingers

------WebKitFormBoundaryYAAP9BVpMwSByNYb--

  """
  var mp: Multipart = initMultipart(header)
  mp.parse(body)
  let tmpPath = mp.getTempDir
  assert mp.len == 2
  echo repeat("-", 30)
  for b in mp:
    case b.dataType
    of MultipartFile:
      assert b.fieldName == "upload"
      assert b.getPath == tmpPath / b.fileId
      assert fileExists(b.getPath)
      let contents = readFile(b.getPath)
      echo "Name: $1=\"$2\"\nPath: $3" % [b.fieldName, b.fileName, b.getPath]
    else:
      echo "Name: $1=\"$2\"" % [b.fieldName, b.value]
    echo repeat("-", 30)
import std/[os, unittest, strutils, sequtils]
import multipart


const initStr = """one two
three-four
-- five six ------
------

------WebKitFormBoundaryYAA04BVpMwSByNYb
Mikey filthy fingers
Dirty docs
Two socks
No jokes"""

test "can parse":
  let
    profilePicture = readFile("tests/assets/cs-black-000.png")
    header = "multipart/form-data; boundary=----WebKitFormBoundaryYAAP9BVpMwSByNYb"
    prefixRaw = """
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

  mp.fileCallback = proc(boundary: ptr Boundary, pos: int, c: ptr char): bool = 
    # use the `fileCallback` to check file contents as they are being collected.
    # echo "File callback called for boundary with field name: ", boundary[].fieldName
    # echo "File name: " & boundary[].fileName & ", pos: " & $pos
    result = true # it must be true to continue collecting the file

  mp.fileSignatureCallback = proc(boundary: ptr Boundary, pos: int, c: ptr char): MultipartFileSigantureState =
    ## Validate PNG magic numbers for the "profile_picture" field.
    ## The callback receives `pos` = number of previously collected signature bytes,
    ## and `c[]` = current byte to be validated.
    if boundary[].fieldName == "profile_picture":
      const pngSig = @[0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8, 0x0D'u8, 0x0A'u8, 0x1A'u8, 0x0A'u8]
      let b = byte(ord(c[]))
      if pos < pngSig.len and b == pngSig[pos]:
        if pos + 1 == pngSig.len:
          echo "Valid PNG signature detected for field: ", boundary[].fieldName
          return stateValidMagic
        else:
          return stateMoreMagic
      else:
        return stateInvalidMagic
    else:
      # For other fields, accept immediately.
      return stateValidMagic

  mp.parse(body)
  
  let tmpPath = mp.getTempDir
  assert mp.len == 6
  
  echo repeat("-", 30)
  for b in mp:
    case b.dataType
    of MultipartFile:
      assert b.getPath == tmpPath / b.fileId
      # checking if file is png by magic numbers
      # assert readFile(b.getPath).startsWith("\x89PNG\r\n\x1a\n")
      
      # check file exists at temp path
      assert fileExists(b.getPath)
      # if  b.fieldName == "profile_picture":
        # assert readFile(b.getPath).len == profilePicture.len
      echo "Name: $1=\"$2\"\nPath: $3" % [b.fieldName, b.fileName, b.getPath]
    else:
      echo "Name: $1=\"$2\"" % [b.fieldName, b.value]
      if b.fieldName == "whitespaces":
        assert b.value.len == 3
    echo repeat("-", 30)
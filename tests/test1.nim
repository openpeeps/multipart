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
$1
------WebKitFormBoundaryYAAP9BVpMwSByNYb--
  """ % [profilePicture]
  var mp: Multipart = initMultipart(header)
  mp.parse(body)
  let tmpPath = mp.getTempDir
  assert mp.len == 6
  
  echo repeat("-", 30)
  for b in mp:
    case b.dataType
    of MultipartFile:
      assert b.getPath == tmpPath / b.fileId
      
      # check file exists at temp path
      assert fileExists(b.getPath)
      if  b.fieldName == "profile_picture":
        assert readFile(b.getPath).len == profilePicture.len
      echo "Name: $1=\"$2\"\nPath: $3" % [b.fieldName, b.fileName, b.getPath]
    else:
      echo "Name: $1=\"$2\"" % [b.fieldName, b.value]
      if b.fieldName == "whitespaces":
        assert b.value.len == 3
    echo repeat("-", 30)
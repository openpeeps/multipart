<p align="center">
  <img src="https://github.com/openpeeps/multipart/blob/main/.github/logo.png" width="140px"><br>
  A simple multipart parser 👑 Written in Nim language
</p>

<p align="center">
  <code>nimble install multipart</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/multipart">API reference</a><br>
  <img src="https://github.com/openpeeps/multipart/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/multipart/workflows/docs/badge.svg" alt="Github Actions">
</p>

## Features
- Parses multipart/form-data content from HTTP requests
- Supports file uploads and text fields
- Progress callbacks for monitoring parsing progress (body start/done, file start/chunk/done)
- Configurable size limits for files and overall body
- Callbacks for handling file data during parsing (magic number validation, custom processing)
- Automatic cleanup of temporary files after processing

## Examples
```nim
import multipart

let inputData = "..." # Your raw multipart/form-data body as a string or byte array
let contentType = "multipart/form-data; boundary=----WebKitFormBoundaryABC123"
  # content type header from the HTTP request, including the boundary

# Progress callback to track parsing progress
proc progressCallback(evt: MultipartProgress) =
  case evt.kind
  of progressBodyStart:
    echo "Parsing started. Total bytes: ", evt.totalBytes
  of progressFileStart:
    echo "File upload started: ", evt.fileName
  of progressFileChunk:
    echo "Processing chunk... Bytes written: ", evt.bytesWritten
  of progressFileDone:
    echo "File upload completed: ", evt.fileName
  of progressBodyDone:
    echo "Parsing completed. Total bytes: ", evt.totalBytes

# Initialize the multipart parser
var mp = initMultipart(contentType, tmpDir = getTempDir() / "multipart_example")
mp.progressCallback = progressCallback
  # optionally, add a progress callback to monitor parsing progress (body start/done, file start/chunk/done)

# Parse the multipart data
mp.parse(inputData)

# Display parsed data
for b in mp:
  case b.dataType
  of MultipartText:
    echo "Text field: ", b.fieldName, " = ", b.value
  of MultipartFile:
    echo "File field: ", b.fieldName, ", File name: ", b.fileName
    if fileExists(b.getPath):
      echo "Stored file path: ", b.getPath
```

If you're looking for a full featured input validator you can use `openpeeps/bag` package to validate input data, forms, including `multipart/form-data`. Give a try https://github.com/openpeeps/bag


### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/multipart/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/multipart/fork)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright &copy; 2024 OpenPeeps & Contributors &mdash; All rights reserved.

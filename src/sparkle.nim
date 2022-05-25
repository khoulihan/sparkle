import std/[strformat, strutils, times, colors, tables, terminal, os, logging]
import std/[asyncnet, asyncdispatch, net, uri, mimetypes]
import docopt
import config


const doc = """
Sparkle - A tiny Gemini server.

Usage:
  sparkle [--directory=<dir>] [--port=<port>]

Options:
  -h --help             Show this screen.
  --version             Show version.
"""

const version = "0.1.0"


const logo = """
.---.             .   .    \ /
\___  ,-. ,-. ,-. | , |  ,-.O -
    \ | | ,-| |   |<  |  |-' \
`---' |-' `-^ '   ' ` `' `-'
      |
      '
"""


var mimedb: MimeDB


type
  StatusCode = enum
    input = 10,
    sensitiveInput = 11,
    success = 20,
    temporaryRedirect = 30,
    permanentRedirect = 31,
    temporaryFailure = 40,
    serverUnavailable = 41,
    cgiError = 42,
    proxyError = 43,
    slowDown = 44,
    permanentFailure = 50,
    notFound = 51,
    gone = 52,
    proxyRequestRefused = 53,
    badRequest = 59,
    clientCertificateRequired = 60,
    certificateNotAuthorised = 61,
    certificateNotValid = 62


template echoAndLog(text: varargs[untyped]) =
  block:
    let ts = now()
    stdout.styledWriteLine(fgCyan, ts.format("yyyy-MM-dd hh:mm:ss'.'fff"), " - ", fgDefault, text)
    # TODO: Also log to a file


template closeIfNecessary(socket: AsyncSocket) =
  if not socket.isClosed():
    socket.close()


proc sendErrorResponse(requestSocket: AsyncSocket, code: StatusCode, meta: string) {.async.} =
  await requestSocket.send(&"{ord(code)} {meta}\r\L")


proc processRequest(requestSocket: AsyncSocket) {.async.} =
  try:
    let request = await requestSocket.recvLine()
    var requestUri: Uri
    try:
      requestUri = parseUri(request)
    except UriParseError:
      let msg = getCurrentExceptionMsg()
      echoAndLog &"Url parse failed: {msg}"
      await requestSocket.sendErrorResponse(StatusCode.badRequest, "Invalid URL")
      return

    echoAndLog("Received request for ", fgBlue, &"{requestUri}", fgDefault, " from ", fgBlue, &"{requestSocket.getPeerAddr()[0]}")

    # TODO: Check if the domain name is correct.
    var filePath = joinPath(srvDir, requestUri.path).absolutePath()
    var (dir, name, ext) = filePath.splitFile()
    if name == "":
      filePath = joinPath(filePath, "index.gmi")
      name = "index"
      ext = ".gmi"
    if not filePath.startsWith(srvDir):
      echoAndLog(fgRed, "Request rejected - outside server root")
      await requestSocket.sendErrorResponse(StatusCode.notFound, "Not Found")
      return
    if not filePath.fileExists():
      echoAndLog(fgRed, "Request rejected - not found")
      await requestSocket.sendErrorResponse(StatusCode.notFound, "Not Found")
      return

    let mt = mimedb.getMimetype(ext, "application/octet-stream")

    await requestSocket.send(&"20 {mt}\r\L")
    await requestSocket.send(readFile(filePath))

  finally:
    requestSocket.closeIfNecessary()


proc serve() {.async.} =
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(1965))
  server.listen()

  while true:
    let req = await server.accept()
    let sslCtx = newContext(certFile = certFile, keyFile = keyFile)

    try:
      wrapConnectedSocket(sslCtx, req, handshakeAsServer)
    except SslError:
      let msg = getCurrentExceptionMsg()
      echoAndLog &"SSL Handshake failed: {msg}"
      req.closeIfNecessary()
      continue

    except:
      let e = getCurrentException()
      let msg = getCurrentExceptionMsg()
      echoAndLog &"Unknown exception ({repr(e)}) occurred during SSL negotiation: {msg}"
      req.closeIfNecessary()
      continue

    try:
      asyncCheck processRequest(req)
    except:
      let e = getCurrentException()
      let msg = getCurrentExceptionMsg()
      echoAndLog &"Unknown exception ({repr(e)}) occurred while handling the request: {msg}"


when isMainModule:
  let args = docopt(doc, version = &"Sparkle {version}")

  # TODO: Add command line parameters for all options
  # Also first run should help the user with basic configuration
  ensureConfigExists()
  try:
    loadConfig(args)
  except ConfigError:
    quit(QuitFailure)

  mimedb = newMimetypes()
  mimedb.register(ext = "gmi", mimetype = "text/gemini")
  mimedb.register(ext = "gemini", mimetype = "text/gemini")

  stdout.styledWrite(fgCyan, logo, fgDefault)
  stdout.styledWriteLine(fgCyan, "Serving from: ", fgDefault, srvDir)
  stdout.styledWriteLine(fgCyan, "Listening on port: ", fgDefault, $port)
  stdout.styledWriteLine(fgCyan, "Cert file: ", fgDefault, certFile)
  stdout.styledWriteLine(fgCyan, "Key file: ", fgDefault, keyFile)

  asyncCheck serve()
  runForever()

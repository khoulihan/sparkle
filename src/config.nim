import std/[os, strutils, terminal]
import parsetoml
import docopt


const DEFAULT_CONFIG = readFile "./config/sparkle.toml"


type
  ConfigVariableSource = enum
    CommandLine,
    Environment,
    ConfigFile,
    Default


type
  ConfigError* = object of CatchableError


let configLocation* = getEnv("SPARKLE_CONFIG_HOME", getConfigDir() & "sparkle" & DirSep)
let cacheLocation* = getEnv("SPARKLE_CACHE_HOME", getCacheDir() & DirSep & "sparkle" & DirSep)
let configFileLocation* = joinPath(configLocation, "sparkle.toml")


var srvDir*: string
var port*: int = 1965
var certFile*: string
var keyFile*: string
var logFile*: string


template saveToFile(fileName, data) =
  var f: File
  if open(f, fileName, fmWrite):
    try:
      f.write(data)
    finally:
      f.close


proc argValueTypeGet[T](value: Value): T =
  when T is string:
    return $value
  elif T is int:
    return parseInt($value)
  elif T is bool:
    return value.toBool
  elif T is seq[string]:
    return @value
  else:
    discard


proc envValueTypeGet[T](envStr: string): T =
  when T is string:
    return envStr
  elif T is int:
    return parseInt(envStr)
  elif T is bool:
    return parseBool(envStr)
  elif T is seq[string]:
    return envStr.split(',')
  else:
    discard


proc confValueTypeGet[T](value: TomlValueRef, default: T): T =
  when T is string:
    return value.getStr(default)
  elif T is int:
    return value.getInt(default)
  elif T is bool:
    return value.getBool(default)
  elif T is seq[string]:
    let values = value.getElems(@[])
    if values.len == 0:
      return default
    result = @[]
    for v in values:
      result.add v.getStr()
  else:
    discard


proc getSetting[T](
  args: Table[string, Value],
  arg: string,
  conf: TomlValueRef,
  confSection: string,
  confKey: string,
  env: string,
  default: T
): T =

  if arg in args:
    if args[arg].kind != vkNone:
      return argValueTypeGet[T](args[arg])

  let envStr = getEnv(env, "")
  if envStr != "":
    return envValueTypeGet[T](envStr)

  result = conf[confSection][confKey].confValueTypeGet[:T](default)


template checkFileExists(fileName, defaultData) =
  if not fileExists(fileName):
    saveToFile(fileName, defaultData)


proc ensureConfigExists*() =
  discard existsOrCreateDir configLocation
  checkFileExists(configFileLocation, DEFAULT_CONFIG)


proc loadConfig*(args: Table[string, Value]) =
  let conf = parsetoml.parseFile(configFileLocation)

  srvDir = getSetting[string](
    args = args,
    arg = "--directory",
    conf = conf,
    confSection = "serve",
    confKey = "directory",
    env = "SPARKLE_SERVE_DIRECTORY",
    default = ""
  )
  if srvDir == "":
    stdout.styledWriteLine(fgRed, "Serve directory not set")
    stdout.styledWriteLine(
      fgDefault,
      "Run ", fgCyan, "`sparkle config`", fgDefault, " to set a permanent configuration, provide",
      " a ", fgCyan, "`--directory`", fgDefault, " parameter, or set the ", fgCyan, "`SPARKLE_SERVE_DIRECTORY`",
      fgDefault, " environment variable"
    )
    raise newException(ConfigError, "Serve directory not set")

  try:
    port = getSetting[int](
      args = args,
      arg = "--port",
      conf = conf,
      confSection = "serve",
      confKey = "port",
      env = "SPARKLE_PORT",
      default = 1965
    )
  except ValueError:
    stdout.styledWriteLine(fgRed, "Invalid port")
    raise newException(ConfigError, "Invalid port")

  certFile = conf["serve"]["cert_file"].getStr
  keyFile = conf["serve"]["key_file"].getStr

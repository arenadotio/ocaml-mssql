open Core
open Async

let tags = [ "lib", "mssql" ]

let log_in_thread level fmt =
  ksprintf (fun str ->
    Thread_safe.run_in_async_exn (fun () ->
      Log.Global.printf ~level ~tags "%s" str)) fmt

let debug fmt = Log.Global.debug ~tags fmt

let debug_in_thread fmt= log_in_thread `Debug fmt

let info fmt = Log.Global.info ~tags fmt

let info_in_thread fmt = log_in_thread `Info fmt

let error fmt = Log.Global.error ~tags fmt

let error_in_thread fmt = log_in_thread `Error fmt

open Async

let tags = [ "lib", "mssql" ]

let debug fmt = Log.Global.debug ~tags fmt

let info fmt = Log.Global.info ~tags fmt

let error fmt = Log.Global.error ~tags fmt

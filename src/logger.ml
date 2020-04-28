open Core

let src = Logs.Src.create "mssql"
let lib_tag = Logs.Tag.def "lib" Format.pp_print_string

let msg ?(tags = Logs.Tag.empty) ?context level fmt =
  Async_helper.safely_run_in_async ?context
  @@ fun () ->
  ksprintf
    (fun msg ->
      Logs.msg ~src level (fun m ->
          let tags = Logs.Tag.add lib_tag "mssql" tags in
          m ~tags "%s" msg))
    fmt
;;

let debug ?tags ?context fmt = msg ?tags ?context Logs.Debug fmt
let info ?tags ?context fmt = msg ?tags ?context Logs.Info fmt
let error ?tags ?context fmt = msg ?tags ?context Logs.Error fmt

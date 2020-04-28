open Core
open Async

let src = Logs.Src.create "mssql"
let lib_tag = Logs.Tag.def "lib" Format.pp_print_string

let msg ?(tags = Logs.Tag.empty) ?context level fmt =
  Async_helper.safely_run_in_async
  @@ fun () ->
  let in_context f =
    match context with
    | Some context ->
      (* Once we're on Async v0.13, use Scheduler.enqueue, since that will apparently pass exceptions
        through correctly *)
      Scheduler.within_context context f
      |> Result.ok
      |> Option.value_exn ~here:[%here] ~message:"Unknown exception in logging"
    | None -> f ()
  in
  in_context
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

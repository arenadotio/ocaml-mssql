open Core
open Async

let with_context ?context f =
  match context with
  | Some context ->
    (* Once we're on Async v0.13, use Scheduler.enqueue, since that will apparently pass exceptions
        through correctly *)
    Scheduler.within_context context f
    |> Result.ok
    |> Option.value_exn ~here:[%here] ~message:"Unknown exception in logging"
  | None -> f ()
;;

(* Run a function in async without the caller needing to keep track.
   If we're already in Async's main thread, just run it, otherwise
   do cross-thread magic *)
let safely_run_in_async ?context f =
  let in_context () = with_context ?context f in
  if Thread_safe.am_holding_async_lock ()
  then in_context ()
  else Thread_safe.run_in_async_exn in_context
;;

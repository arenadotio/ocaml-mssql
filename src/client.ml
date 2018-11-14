open Core
open Async
open Freetds

type t =
  (* dbprocess will be set to None when closed to prevent null pointer crashes *)
  (* The sequencer prevents concurrent use of the DB connection, and also
     prevent queries during unrelated transactions. *)
  { mutable conn : Dblib.dbprocess Sequencer.t option
  (* ID used to detect deadlocks when attempting to use an outer DB handle
     inside of with_transaction *)
  ; transaction_id : Bigint.t
  (* Months are sometimes 0-based and sometimes 1-based. See:
     http://www.pymssql.org/en/stable/freetds_and_dates.html *)
  ; month_offset : int }

let next_transaction_id =
  let next = ref Bigint.zero in
  fun () ->
    let current = !next in
    next := Bigint.(one + current);
    current

let parent_transactions_key =
  Univ_map.Key.create ~name:"mssql_parent_transactions" [%sexp_of: Bigint.Set.t]

let sequencer_enqueue t f =
  match t.conn with
  | None ->
    failwith "Attempt to use closed DB"
  | Some conn ->
    Scheduler.find_local parent_transactions_key
    |> function
    | Some parent_transactions
      when Set.mem parent_transactions t.transaction_id ->
      failwith "Attempted to use outer DB handle inside of with_transaction. \
                This would have lead to a deadlock."
    | _ ->
      Throttle.enqueue conn f

let run_query ~month_offset t query =
  Logger.debug_in_thread !"Executing query: %s" query;
  let colnames t =
    Dblib.numcols t
    |> List.range 0
    |> List.map ~f:(fun i -> Dblib.colname t (i + 1))
  in
  Dblib.canquery t;
  Dblib.sqlexec t query;
  let rec result_set_loop result_sets =
    match Dblib.results t with
    | true ->
      let colnames = colnames t in
      let rec loop rows colnames =
        Result.try_with (fun () -> Dblib.nextrow t)
        |> function
        | Ok row ->
          let row = Row.create_exn ~month_offset row colnames in
          loop (row :: rows) colnames
        | Error Caml.Not_found ->
          List.rev rows :: result_sets
          |> result_set_loop
        | Error e -> raise e
      in
      loop [] colnames
    | false -> result_sets
  in
  result_set_loop []
  |> List.rev

let format_query query params =
  let params =
    List.map params ~f:Db_field.to_string_escaped
    |> Array.of_list
  in
  let lexbuf = Lexing.from_string query in
  Query_parser.main Query_lexer.token lexbuf
  |> List.map ~f:(
    let open Query_parser_types in
    function
    | Other s -> s
    | Param n ->
      (* $1 is the first param *)
      let i = n - 1 in
      if i < 0 then
        failwithf !"Query has param $%d but params should start at $1. \
                    Query:\n%s\n\n\
                    Params: %{sexp: string array}" n query params ();
      let len = Array.length params in
      if i >= len then
        failwithf !"Query has param $%d but there are only %d params. \
                    Query:\n%s\n\n\
                    Params: %{sexp: string array}" n len query params ();
      Array.get params i)
  |> String.concat ~sep:""

let execute' ({ month_offset } as t) query =
  sequencer_enqueue t @@ fun conn ->
  In_thread.run (fun () ->
    run_query ~month_offset conn query)

let with_query_in_exn query formatted_query f =
  let%map oe = Monitor.try_with_or_error f in
  Or_error.tag oe ~tag:(sprintf "Formatted query was %s" formatted_query)
  |> Or_error.tag ~tag:(sprintf "Query was %s" query)
  |> Or_error.ok_exn

let execute_multi_result ?(params=[]) conn query =
  let formatted_query = format_query query params in
  with_query_in_exn query formatted_query @@ fun () ->
  execute' conn formatted_query

let execute ?params conn query =
  execute_multi_result ?params conn query
  >>| function
  | [] -> []
  | result_set :: [] -> result_set
  | result_sets ->
    failwithf !"Mssql.execute expected one result set but got %d result sets: \
                %{sexp: Row.t list list}"
      (List.length result_sets) result_sets ()

let execute_unit ?params conn query =
  execute ?params conn query
  >>| function
  | [] -> ()
  | rows ->
    failwithf !"Mssql.execute_unit expected no results but got %d rows: \
                %{sexp: Row.t list}" (List.length rows) rows ()

let execute_single ?params conn query =
  execute ?params conn query
  >>| function
  | [] -> None
  | row :: [] -> Some row
  | rows ->
    failwithf !"Mssql.execute_single expected 0 or 1 results but got %d rows: \
                %{sexp: Row.t list}" (List.length rows) rows ()

let execute_many ~params conn query =
  let formatted_query =
    List.map params ~f:(format_query query)
    |> String.concat ~sep:";"
  in
  with_query_in_exn query formatted_query @@ fun () ->
  execute' conn formatted_query

let begin_transaction conn =
  execute_unit conn "BEGIN TRANSACTION"

let commit conn =
  execute_unit conn "COMMIT"

let rollback conn =
  execute_unit conn "ROLLBACK"

let with_transaction' t f =
  (* Use the sequencer to prevent any other copies of this DB handle from
     executing during the transaction *)
  sequencer_enqueue t @@ fun conn ->
  Scheduler.find_local parent_transactions_key
  |> Option.value ~default:Bigint.Set.empty
  |> Fn.flip Set.add t.transaction_id
  |> Option.some
  |> Scheduler.with_local parent_transactions_key ~f:(fun () ->
    (* Make a new sub-sequencer so our own queries can continue *)
    let t =
      { t with
        conn =
          Sequencer.create ~continue_on_error:true conn
          |> Option.some
      ; transaction_id = next_transaction_id () }
    in
    let%bind () = begin_transaction t in
    let%bind res = f t in
    let%map () = match res with
      | Ok _ -> commit t
      | Error _ -> rollback t
    in
    res)

let with_transaction t f =
  with_transaction' t (fun t ->
    Monitor.try_with (fun () ->
      f t))
  >>| function
  | Ok res ->
    res
  | Error exn ->
    raise exn

let with_transaction_or_error t f =
  with_transaction' t (fun t ->
    Monitor.try_with_join_or_error (fun () ->
      f t))

let ignore_conversion_err_handler severity _err msg =
  match severity with
  | Dblib.CONVERSION ->
    Logger.info "Ignoring conversion error: %s" msg;
  | _ -> raise (Dblib.Error(severity, msg))

let rec connect ?(tries=5) ~host ~db ~user ~password () =
  try
    let conn =
      Dblib.connect
        ~user ~password
        (* We have issues with anything higher than this *)
        ~version:Dblib.V70
        (* Clifford gives FreeTDS conversion errors if we choose anything else,
           eg:
           ("Error(CONVERSION, \"Some character(s) could not be converted into
           client's character set.  Unconverted bytes were changed to question
           marks ('?')\")") *)
        ~charset:"CP1252"
        host
    in
    Dblib.use conn db;
    Dblib.err_handler ignore_conversion_err_handler;
    conn
  with exn ->
    if tries = 0 then
      raise exn
    else
      Logger.info_in_thread "Retrying Mssql.connect due to exn: %s" (Exn.to_string exn);
      connect ~tries:(tries-1) ~host ~db ~user ~password ()

(* These need to be on for some reason, eg: DELETE failed because the following
   SET options have incorrect settings: 'ANSI_NULLS, QUOTED_IDENTIFIER,
   CONCAT_NULL_YIELDS_NULL, ANSI_WARNINGS, ANSI_PADDING'. Verify that SET
   options are correct for use with indexed views and/or indexes on computed
   columns and/or filtered indexes and/or query notifications and/or XML data
   type methods and/or spatial index operations.*)
let init_conn c =
  execute_multi_result c
    "SET QUOTED_IDENTIFIER ON
     SET ANSI_NULLS ON
     SET ANSI_WARNINGS ON
     SET ANSI_PADDING ON
     SET CONCAT_NULL_YIELDS_NULL ON"
  |> Deferred.ignore

let close ({ conn } as t) =
  match conn with
  (* already closed *)
  | None -> Deferred.unit
  | Some conn ->
    t.conn <- None;
    Throttle.enqueue conn @@ fun conn ->
    In_thread.run (fun () -> Dblib.close conn)

let create ~host ~db ~user ~password () =
  let%bind conn =
    let%map conn =
      In_thread.run (connect ~host ~db ~user ~password)
      >>| Sequencer.create ~continue_on_error:true
    in
    { conn = Some conn
    ; transaction_id = next_transaction_id ()
    ; month_offset = 0 }
  in
  Monitor.try_with begin fun () ->
    (* Since FreeTDS won't tell us if it was compiled with 0-based month or
       1-based months, make a query to check when we first startup and keep
       track of the offset so we can correct it. *)
    execute conn "SELECT CAST('2017-02-02' AS DATETIME) AS x"
    >>= function
    | [ row ] ->
      let month_offset =
        Row.datetime_exn row "x"
        |> Time.(to_date ~zone:Zone.utc)
        |> Date.month
        |> function
        | Month.Feb -> 0
        | Month.Jan -> 1
        | _ -> assert false
      in
      let conn = { conn with month_offset } in
      init_conn conn
      >>| fun () ->
      conn
    | _ -> assert false
  end
  >>= function
  | Ok res -> return res
  | Error exn ->
    let%map () = close conn in
    raise exn

let with_conn ~host ~db ~user ~password f =
  let%bind conn = create ~host ~db ~user ~password () in
  Monitor.protect (fun () -> f conn) ~finally:(fun () -> close conn)

(* FIXME: There's a bunch of other stuff we should really reset, but
   SQL Server doesn't publically expose sp_reset_connect :( *)
let cleanup_connection conn =
  (* rollback transactions until there are none left *)
  Deferred.repeat_until_finished () (fun () ->
    Monitor.try_with (fun () ->
      rollback conn)
    >>| function
    | Ok _ -> `Repeat ()
    | Error _ -> `Finished ())

module Pool = struct
  type p =
    { make : unit -> t Deferred.t
    ; connections : t option ref Throttle.t }

  let with_pool ~host ~db ~user ~password ?(max_connections=10) f =
    let make = create ~host ~db ~user ~password in
    let connections =
      List.init max_connections ~f:(fun _ -> ref None)
      |> Throttle.create_with ~continue_on_error:true
    in
    Throttle.at_kill connections (fun conn ->
      match !conn with
      | Some conn -> close conn
      | None -> return ());
    let%map res = f { make ; connections } in
    Throttle.kill connections;
    res

  let with_conn { make ; connections } f =
    let pool_conn_close conn =
      match !conn with
      | Some c ->
        Monitor.try_with (fun () ->
          close c)
        (* Intentionally ignore any errors when closing the broken
           connection *)
        >>| fun _ ->
        conn := None
      | None -> Deferred.unit
    in
    Throttle.enqueue connections (fun conn ->
      (* Check if the connection is good; close it if it's not *)
      (match !conn with
       | Some c ->
         Monitor.try_with (fun () -> execute c "SELECT 1")
         >>= (function
           | Ok _ -> return ()
           | Error exn ->
             Exn.to_string exn
             |> Logger.error "Closing bad MSSQL connection due to exn: %s";
             pool_conn_close conn)
       | None -> return ())
      >>= fun () ->
      (* Find or open a connection *)
      let%bind c =
        match !conn with
        | Some c -> return c
        | None ->
          let%map c = make () in
          conn := Some c;
          c
      in
      (* Run our actual target function *)
      Monitor.try_with (fun () ->
        let%bind res = f c in
        let%map () = cleanup_connection c in
        res)
      >>= function
      | Ok res -> return res
      | Error exn ->
        let backtrace = Caml.Printexc.get_raw_backtrace () in
        let%map () = pool_conn_close conn in
        Caml.Printexc.raise_with_backtrace exn backtrace)
end

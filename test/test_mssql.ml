open Core
open Async
open OUnit2

module Row = Mssql.Row

let ae_sexp ?cmp ?pp_diff ?msg sexp a a' =
  let cmp = Option.value cmp ~default:(fun a b -> sexp a = sexp b) in
  assert_equal ~cmp ?pp_diff ?msg
    ~printer:(fun x -> x |> sexp |> Sexp.to_string_hum) a a'

let async_test' ctx timeout f =
  Thread_safe.block_on_async_exn @@ fun () ->
  [ Log.Output.create ~flush:(Fn.const Deferred.unit) (fun msgs ->
      Queue.iter msgs ~f:(fun msg ->
        let level : OUnit2.log_severity =
          match Log.Message.level msg with
          | None | Some `Debug | Some `Info -> `Info
          | Some `Error -> `Error
        in
        OUnit2.logf ctx level "%s" (Log.Message.message msg));
      Deferred.unit) ]
  |> Log.Global.set_output;
  Clock.with_timeout timeout (f ())
  >>| function
  | `Result x -> x
  | `Timeout ->
    failwithf "Test exceeded timeout of %f seconds"
      (Time.Span.to_sec timeout) ()

let async_test ctx f =
  async_test' ctx (Time.Span.of_sec 10.) f

let test_select_and_convert () =
  Mssql.Test.with_conn (fun db ->
    Mssql.execute db ("SELECT 1 AS intcol, 0 AS intcol2, 3 AS notboolint, \
                       -1 AS notboolint2, 5.9 AS floatcol, \
                       'some string' AS strcol, '' AS emptystrcol, \
                       '2017-01-05' AS datecol, \
                       CAST('1998-09-12T12:34:56Z' AS DATETIME) AS datetimecol, \
                       CONVERT(BIT, 1) AS boolcol, NULL AS nullcol"))
  >>| function
  | [ row ] ->
    let assert_raises msg f =
      match Or_error.try_with f with
      | Ok _ -> assert_failure ("Expected exception for conversion: " ^ msg)
      | Error _ -> ()
    in
    let col = "intcol" in
    ae_sexp [%sexp_of: int option] (Some 1) (Row.int row col);
    ae_sexp [%sexp_of: int32 option] (Some Int32.one) (Row.int32 row col);
    ae_sexp [%sexp_of: int64 option] (Some Int64.one) (Row.int64 row col);
    ae_sexp [%sexp_of: float option] (Some 1.) (Row.float row col);
    ae_sexp [%sexp_of: string option] (Some "1") (Row.str row col);
    ae_sexp [%sexp_of: bool option] (Some true) (Row.bool row col);
    assert_raises "int as date" (fun () -> Row.date row col);
    assert_raises "int as datetime" (fun () -> Row.datetime row col);

    let col = "intcol2" in
    ae_sexp [%sexp_of: int option] (Some 0) (Row.int row col);
    ae_sexp [%sexp_of: int32 option] (Some Int32.zero) (Row.int32 row col);
    ae_sexp [%sexp_of: int64 option] (Some Int64.zero) (Row.int64 row col);
    ae_sexp [%sexp_of: float option] (Some 0.) (Row.float row col);
    ae_sexp [%sexp_of: string option] (Some "0") (Row.str row col);
    ae_sexp [%sexp_of: bool option] (Some false) (Row.bool row col);
    assert_raises "int as date" (fun () -> Row.date row col);
    assert_raises "int as datetime" (fun () -> Row.datetime row col);

    let col = "notboolint" in
    ae_sexp [%sexp_of: int option] (Some 3) (Row.int row col);
    ae_sexp [%sexp_of: int32 option] (Int32.of_int 3) (Row.int32 row col);
    ae_sexp [%sexp_of: int64 option] (Some (Int64.of_int 3))
      (Row.int64 row col);
    ae_sexp [%sexp_of: float option] (Some 3.) (Row.float row col);
    ae_sexp [%sexp_of: string option] (Some "3") (Row.str row col);
    assert_raises "int as date" (fun () -> Row.date row col);
    assert_raises "int as datetime" (fun () -> Row.datetime row col);
    assert_raises "int as bool" (fun () -> Row.bool row col);

    let col = "notboolint2" in
    ae_sexp [%sexp_of: int option] (Some (-1)) (Row.int row col);
    ae_sexp [%sexp_of: int32 option] (Int32.of_int (-1)) (Row.int32 row col);
    ae_sexp [%sexp_of: int64 option] (Some (Int64.of_int (-1)))
      (Row.int64 row col);
    ae_sexp [%sexp_of: float option] (Some (-1.)) (Row.float row col);
    ae_sexp [%sexp_of: string option] (Some "-1") (Row.str row col);
    assert_raises "int as date" (fun () -> Row.date row col);
    assert_raises "int as datetime" (fun () -> Row.datetime row col);
    assert_raises "int as bool" (fun () -> Row.bool row col);

    let col = "floatcol" in
    ae_sexp [%sexp_of: float option] (Some 5.9) (Row.float row col);
    ae_sexp [%sexp_of: string option] (Some "5.9") (Row.str row col);
    ae_sexp [%sexp_of: int option] (Some 5) (Row.int row col);
    ae_sexp [%sexp_of: int32 option] (Int32.of_int 5) (Row.int32 row col);
    ae_sexp [%sexp_of: int64 option] (Some (Int64.of_int 5))
      (Row.int64 row col);
    assert_raises "float as date" (fun () -> Row.date row col);
    assert_raises "float as datetime" (fun () -> Row.datetime row col);
    assert_raises "float as bool" (fun () -> Row.bool row col);

    let col = "strcol" in
    ae_sexp [%sexp_of: string option] (Some "some string")
      (Mssql.Row.str row col);
    assert_raises "string as float" (fun () -> Row.float row col);
    assert_raises "string as int" (fun () -> Row.int row col);
    assert_raises "string as int32" (fun () -> Row.int32 row col);
    assert_raises "string as int64" (fun () -> Row.int64 row col);
    assert_raises "string as date" (fun () -> Row.date row col);
    assert_raises "string as datetime" (fun () -> Row.datetime row col);
    assert_raises "string as bool" (fun () -> Row.bool row col);

    let col = "emptystrcol" in
    ae_sexp [%sexp_of: string option] (Some "")
      (Mssql.Row.str row col);
    assert_raises "string as float" (fun () -> Row.float row col);
    assert_raises "string as int" (fun () -> Row.int row col);
    assert_raises "string as int32" (fun () -> Row.int32 row col);
    assert_raises "string as int64" (fun () -> Row.int64 row col);
    assert_raises "string as date" (fun () -> Row.date row col);
    assert_raises "string as datetime" (fun () -> Row.datetime row col);
    assert_raises "string as bool" (fun () -> Row.bool row col);

    let col = "datecol" in
    ae_sexp [%sexp_of: string option] (Some "2017-01-05") (Mssql.Row.str row col);
    ae_sexp [%sexp_of: Date.t option] (Some (Date.of_string "2017-01-05"))
      (Mssql.Row.date row col);
    assert_raises "date as float" (fun () -> Row.float row col);
    assert_raises "date as int" (fun () -> Row.int row col);
    assert_raises "date as int32" (fun () -> Row.int32 row col);
    assert_raises "date as int64" (fun () -> Row.int64 row col);
    assert_raises "date as bool" (fun () -> Row.bool row col);

    let col = "datetimecol" in
    ae_sexp [%sexp_of: string option] (Some "1998-09-12 12:34:56.000000Z")
      (Row.str row col);
    ae_sexp [%sexp_of: Date.t option] (Some (Date.of_string "1998-09-12"))
      (Row.date row col);
    ae_sexp [%sexp_of: Time.t option] (Some (Time.of_string_abs "1998-09-12T12:34:56Z"))
      (Row.datetime row col);
    assert_raises "datetime as float" (fun () -> Row.float row col);
    assert_raises "datetime as int" (fun () -> Row.int row col);
    assert_raises "datetime as int32" (fun () -> Row.int32 row col);
    assert_raises "datetime as int64" (fun () -> Row.int64 row col);
    assert_raises "datetime as bool" (fun () -> Row.bool row col);

    let col = "boolcol" in
    ae_sexp [%sexp_of: string option] (Some "true") (Row.str row col);
    ae_sexp [%sexp_of: bool option] (Some true) (Row.bool row col);
    ae_sexp [%sexp_of: int option] (Some 1) (Row.int row col);
    ae_sexp [%sexp_of: int32 option] (Some Int32.one) (Row.int32 row col);
    ae_sexp [%sexp_of: int64 option] (Some Int64.one) (Row.int64 row col);
    assert_raises "bool as float" (fun () -> Row.float row col);
    assert_raises "bool as date" (fun () -> Row.date row col);
    assert_raises "bool as datetime" (fun () -> Row.datetime row col);

    let col = "nullcol" in
    ae_sexp [%sexp_of: string option] None (Row.str row col);
    ae_sexp [%sexp_of: float option] None (Row.float row col);
    ae_sexp [%sexp_of: int option] None (Row.int row col);
    ae_sexp [%sexp_of: int32 option] None (Row.int32 row col);
    ae_sexp [%sexp_of: int64 option] None (Row.int64 row col);
    ae_sexp [%sexp_of: Date.t option] None (Row.date row col);
    ae_sexp [%sexp_of: Time.t option] None (Row.datetime row col);
    ae_sexp [%sexp_of: bool option] None (Row.bool row col)
  | _ -> assert false

let test_multiple_queries_in_execute () =
  Mssql.Test.with_conn (fun db ->
    Monitor.try_with @@ fun () ->
    Mssql.execute db "SELECT 1; SELECT 2")
  >>| Result.is_error
  >>| assert_bool "Multiple queries in execute should throw exception but didn't"

let test_multiple_queries_in_execute_multi_result () =
  Mssql.Test.with_conn (fun db ->
    Mssql.execute_multi_result db "SELECT 1; SELECT 2")
  >>| List.map ~f:(List.map ~f:(fun row -> Row.int row ""))
  >>| ae_sexp [%sexp_of: int option list list] [[ Some 1 ] ; [ Some 2 ]]

let test_execute_unit () =
  Mssql.Test.with_conn (fun db ->
    [ "SET XACT_ABORT ON"
    ; "BEGIN TRANSACTION"
    ; "CREATE TABLE #test (id int)"
    ; "INSERT INTO #test (id) VALUES (1)"
    ; "UPDATE #test SET id = 2 WHERE id = 1"
    ; "COMMIT TRANSACTION" ]
    |> Deferred.List.iter ~how:`Sequential ~f:(Mssql.execute_unit db))

let test_execute_unit_fail () =
  Mssql.Test.with_conn (fun db ->
    Mssql.execute_unit db "CREATE TABLE #test (id int)"
    >>= fun () ->
    Mssql.execute_unit db "INSERT INTO #test (id) VALUES (1)"
    >>= fun () ->
    Monitor.try_with @@ fun () ->
    Mssql.execute_unit db "SELECT id FROM #test")
  >>| Result.is_error
  >>| assert_bool "execute_unit with a SELECT should throw but didn't"

let test_execute_single () =
  Mssql.Test.with_conn (fun db ->
    Mssql.execute_unit db "CREATE TABLE #test (id int)"
    >>= fun () ->
    Mssql.execute_unit db "INSERT INTO #test (id) VALUES (1)"
    >>= fun () ->
    Mssql.execute_single db "SELECT id FROM #test WHERE id = 1")
  >>| ignore

let test_execute_single_fail () =
  Mssql.Test.with_conn (fun db ->
    Mssql.execute_unit db "CREATE TABLE #test (id int)"
    >>= fun () ->
    Mssql.execute_unit db "INSERT INTO #test (id) VALUES (1), (1)"
    >>= fun () ->
    Monitor.try_with @@ fun () ->
    Mssql.execute_single db "SELECT id FROM #test WHERE id > 0")
  >>| Result.is_error
  >>| assert_bool "execute_single returning multiple rows should throw \
                   but didn't"

let test_order () =
  Mssql.Test.with_conn (fun db ->
    Mssql.execute db "SELECT 1 AS a UNION ALL SELECT 2 AS a")
  >>| fun rows ->
  let values = List.map rows ~f:(fun row ->
    Row.int row "a")
  in
  ae_sexp [%sexp_of: int option list] [ Some 1 ; Some 2 ] values

let test_param_parsing () =
  let params = Mssql.Param.([ Some (String "'") ; Some (Int 5)
                            ; None ]) in
  Mssql.Test.with_conn (fun db ->
    Mssql.execute ~params db "SELECT $1 AS single_quote, \
                              $2 AS five, \
                              '$1' AS \"$2\", \
                              '''$1' AS \"\"\"$2\", \
                              $3 AS none")
  >>| function
  | [ row ] ->
    let single_quote = Row.str row "single_quote" in
    ae_sexp [%sexp_of: string option] (Some "'") single_quote;
    let five = Row.int row "five" in
    ae_sexp [%sexp_of: int option] (Some 5) five;
    let dollar_str = Row.str row "$2" in
    ae_sexp [%sexp_of: string option] (Some "$1") dollar_str;
    let dollar_dollar_str = Row.str row "\"$2" in
    ae_sexp [%sexp_of: string option] (Some "'$1") dollar_dollar_str;
    let none = Row.str row "none" in
    ae_sexp [%sexp_of: string option] None none;
  | rows -> failwithf !"Expected one row but got %{sexp: Mssql.Row.t list}" rows ()

let test_param_out_of_range () =
  let open Mssql.Param in
  Mssql.Test.with_conn (fun db ->
    [ Some [ Some(String "asdf") ; Some (Int 9) ],
      "SELECT $1 AS a, \
       $2 AS b, \
       $3 AS c",
      "Query has param $3 but there are only 2 params."
    ; Some [ Some(String "asdf") ; Some (Int 9) ],
      "SELECT $1 AS a, \
       $2 AS b, \
       $0 AS c",
      "Query has param $0 but params should start at $1."
    ; None,
      "SELECT $1 AS a, \
       $2 AS b",
      "Query has param $1 but there are only 0 params." ]
    |> Deferred.List.iter ~f:(fun (expect_params, expect_query, expect_msg) ->
      Monitor.try_with ~extract_exn:true (fun () ->
        Mssql.execute ?params:expect_params db expect_query
        >>| ignore)
      >>| function
      | Ok _ ->
        assert_failure "Command should have thrown param out of range exception"
      | Error (Mssql.Error { msg ; query
                           ; params }) ->
        ae_sexp [%sexp_of: string] expect_msg msg;
        ae_sexp [%sexp_of: string option] (Some expect_query) query;
        ae_sexp [%sexp_of: Mssql.Param.t option list]
          (Option.value ~default:[] expect_params) params
      | Error exn ->
        assert_failure (sprintf "Expected Mssql_error but got %s"
                          (Exn.to_string exn))))

let round_trip_tests =
  let all_chars = String.init 128 ~f:Char.of_int_exn in
  let open Mssql.Param in
  [ String "", "VARCHAR(10)",
    (fun row ->
       Row.str row ""
       |> ae_sexp [%sexp_of: string option] (Some ""))
  ; Bignum (Bignum.of_string "9223372036854775808"), "NUMERIC(38)",
    (fun row ->
       Row.bignum row ""
       |> ae_sexp [%sexp_of: Bignum.t option]
            (* FIXME: Why are we losing precision ? *)
            (Some (Bignum.of_string "9223372036854775808")))
  ; Bool true, "BIT",
    (fun row ->
       Row.bool row ""
       |> ae_sexp [%sexp_of: bool option] (Some true))
  ; Bool false, "BIT",
    (fun row ->
       Row.bool row ""
       |> ae_sexp [%sexp_of: bool option] (Some false))
  ; Float 3.1415, "FLOAT",
    (fun row ->
       Row.float row ""
       |> ae_sexp [%sexp_of: float option] (Some 3.1415))
  ; Int 5, "INT",
    (fun row ->
       Row.int row ""
       |> ae_sexp [%sexp_of: int option] (Some 5))
  ; Int32 Int32.max_value, "INT",
    (fun row ->
       Row.int32 row ""
       |> ae_sexp [%sexp_of: int32 option] (Some Int32.max_value))
  (* FIXME: If we sent Int64.max, SQL Server returns it as a FLOAT with
     rounding errors, even though we're explicitly casting to BIGINT. *)
  ; Int64 Int64.(max_value / of_int 1000000), "BIGINT",
    (fun row ->
       Row.int64 row ""
       |> ae_sexp [%sexp_of: int64 option]
            (Some Int64.(max_value / of_int 1000000)))
  ; Date (Time.of_string "2017-01-05 11:53:02Z"), "DATETIME",
    (fun row ->
       Row.datetime row ""
       |> ae_sexp [%sexp_of: Time.t option]
            (Some (Time.of_string "2017-01-05 11:53:02Z"))) ]
  @
  ([ all_chars
   (* try null, ' and a string in any order to make sure the iterative code
      is correct *)
   ; "\x00a'"
   ; "\x00'asd"
   ; "'\x00asd"
   ; "'asd\x00"
   ; "asd\x00"
   ; "asd'\x00'" ]
   |> List.map ~f:(fun str ->
     (String str, "VARCHAR(256)", (fun row ->
        Row.str row ""
        |> ae_sexp [%sexp_of: string option] (Some str)))))
  |> List.map ~f:(fun (param, type_name, f) ->
    (sprintf "test_round_trip %s" type_name), fun () ->
      let params = [ Some param ] in
      let query = sprintf "SELECT CAST($1 AS %s)" type_name in
      Mssql.Test.with_conn (fun db ->
        Mssql.execute ~params db query)
      >>| function
      | [ row ] -> f row
      | rows ->
        failwithf !"Expected one row but got %{sexp: Mssql.Row.t list}" rows ())

let test_execute_many () =
  let expect =
    List.init 100 ~f:(fun i -> [ Some i ])
  in
  let params =
    List.init 100 ~f:(fun i -> Mssql.Param.([ Some (Int i) ]))
  in
  Mssql.Test.with_conn (fun db ->
    Mssql.execute_many ~params db "SELECT $1 AS result")
  >>| List.map ~f:(fun result_set ->
    List.map result_set ~f:(fun row ->
      Mssql.Row.int row "result"))
  >>| ae_sexp [%sexp_of: int option list list] expect

let test_concurrent_queries () =
  let n = 10 in
  let query =
    List.range 1 (n + 1)
    |> List.map ~f:(sprintf "SELECT $%d")
    |> String.concat ~sep:" UNION ALL "
  in
  Mssql.Test.with_conn (fun db ->
    List.range 0 n
    |> Deferred.List.iter ~how:`Parallel ~f:(fun _ ->
      let vals = List.init n ~f:(fun _ -> Random.int 10000) in
      let expect = List.map vals ~f:Option.some in
      let params = List.map vals ~f:(fun n -> Some (Mssql.Param.Int n)) in
      Mssql.execute ~params db query
      >>| List.map ~f:(fun row ->
        Row.int row "")
      >>| ae_sexp [%sexp_of: int option list] expect))

let test_connection_pool_concurrency () =
  let n = 10 in
  let query =
    List.range 1 (n + 1)
    |> List.map ~f:(sprintf "SELECT $%d")
    |> String.concat ~sep:" UNION ALL "
  in
  Mssql.Test.with_pool ~max_connections:n (fun pool ->
    List.init n ~f:(fun _ ->
      let vals = List.init n ~f:(fun _ -> Random.int 10000) in
      let expect = List.map vals ~f:Option.some in
      let params = List.map vals ~f:(fun n -> Some (Mssql.Param.Int n)) in
      params, expect)
    |> Deferred.List.iter ~how:`Parallel ~f:(fun (params, expect) ->
      Mssql.Pool.with_conn pool (fun db ->
        Mssql.execute ~params db query
        >>| List.map ~f:(fun row ->
          Row.int row "")
        >>| ae_sexp [%sexp_of: int option list] expect)))

let recoding_tests =
  (* ç ß are different in CP1252 vs UTF-8; ∑ has no conversion *)
  [ "valid UTF-8",
    "ç ß ∑ We’re testing iconv here",
    (* round trip strips ∑ because we can't store it, but handles the rest *)
    "ç ß  We’re testing iconv here",
    (* Inserting the literal char codes, we'll double-decode when we pull it
       back out of the DB (garbage output is by design here) *)
    "Ã§ ÃŸ âˆ‘ Weâ€™re testing iconv here"
  ; "invalid UTF-8",
    (* \x81 isn't valid in UTF-8 or CP1252 so both versions fallback to just
       using the ASCII chars *)
    "ç ß ∑ We’re testing iconv here \x81",
    "ç ß  We’re testing iconv here ",
    "Ã§ ÃŸ âˆ‘ Weâ€™re testing iconv here " ]
  |> List.concat_map ~f:(fun (name, input, expect_roundtrip, expect_charcodes) ->
    [ "recoding, round-trip " ^ name, (fun () ->
        let params = [ Some (Mssql.Param.String input) ] in
        Mssql.Test.with_conn @@ fun db ->
        Mssql.execute_single ~params db "SELECT $1"
        >>| Option.map ~f:Row.to_alist
        >>| ae_sexp [%sexp_of: (string * string) list option] (Some [ "", expect_roundtrip ]))
    ; "recoding, sending literal char codes " ^ name, (fun () ->
        Mssql.Test.with_conn @@ fun db ->
        String.to_list input
        |> List.map ~f:Char.to_int
        |> List.map ~f:(sprintf "CHAR(%d)")
        |> String.concat ~sep:"+"
        |> sprintf "SELECT %s"
        |> Mssql.execute_single db
        >>| Option.map ~f:Row.to_alist
        >>| ae_sexp [%sexp_of: (string * string) list option] (Some [ "", expect_charcodes ]))
    ])

let test_rollback () =
  let expect = [ [ "id", "1" ] ] in
  Mssql.Test.with_conn @@ fun db ->
  let%bind () = Mssql.execute_unit db "CREATE TABLE #test (id int)" in
  let%bind () = Mssql.execute_unit db "INSERT INTO #test VALUES (1)" in
  let%bind () = Mssql.begin_transaction db in
  let%bind () = Mssql.execute_unit db "INSERT INTO #test VALUES (2)" in
  let%bind () = Mssql.rollback db in
  Mssql.execute db "SELECT id FROM #test"
  >>| List.map ~f:Mssql.Row.to_alist
  >>| ae_sexp [%sexp_of: (string * string) list list] expect

let test_auto_rollback () =
  let expect = [ [ "id", "1" ] ] in
  Mssql.Test.with_conn @@ fun db ->
  let%bind () = Mssql.execute_unit db "CREATE TABLE #test (id int)" in
  let%bind () = Mssql.execute_unit db "INSERT INTO #test VALUES (1)" in
  Monitor.try_with ~extract_exn:true (fun () ->
    Mssql.with_transaction db (fun db ->
      let%bind () = Mssql.execute_unit db "INSERT INTO #test VALUES (2)" in
      raise Caml.Not_found))
  >>= function
  | Error Caml.Not_found ->
    Mssql.execute db "SELECT id FROM #test"
    >>| List.map ~f:Mssql.Row.to_alist
    >>| ae_sexp [%sexp_of: (string * string) list list] expect
  | _ -> assert false

let test_commit () =
  let expect = [ [ "id", "1" ]
               ; [ "id", "2" ] ] in
  Mssql.Test.with_conn @@ fun db ->
  let%bind () = Mssql.execute_unit db "CREATE TABLE #test (id int)" in
  let%bind () = Mssql.execute_unit db "INSERT INTO #test VALUES (1)" in
  let%bind () = Mssql.begin_transaction db in
  let%bind () = Mssql.execute_unit db "INSERT INTO #test VALUES (2)" in
  let%bind () = Mssql.commit db in
  Mssql.execute db "SELECT id FROM #test"
  >>| List.map ~f:Mssql.Row.to_alist
  >>| ae_sexp [%sexp_of: (string * string) list list] expect

let test_auto_commit () =
  let expect = [ [ "id", "1" ]
               ; [ "id", "2" ] ] in
  Mssql.Test.with_conn @@ fun db ->
  let%bind () = Mssql.execute_unit db "CREATE TABLE #test (id int)" in
  let%bind () = Mssql.execute_unit db "INSERT INTO #test VALUES (1)" in
  Mssql.with_transaction db (fun db ->
    Mssql.execute_unit db "INSERT INTO #test VALUES (2)")
  >>= fun () ->
  Mssql.execute db "SELECT id FROM #test"
  >>| List.map ~f:Mssql.Row.to_alist
  >>| ae_sexp [%sexp_of: (string * string) list list] expect

let test_other_execute_during_transaction () =
  Mssql.Test.with_conn @@ fun db ->
  let%bind () = Mssql.execute_unit db "CREATE TABLE #test (id int)" in
  let ivar = Ivar.create () in
  let%map () =
    Mssql.with_transaction db (fun db ->
      Ivar.fill ivar ();
      let%bind () = Mssql.execute_unit db "WAITFOR DELAY '00:00:01'" in
      Mssql.execute_unit db "INSERT INTO #test VALUES (1)")
  and res =
    let%bind () = Ivar.read ivar in
    Mssql.execute db "SELECT id FROM #test"
    >>| List.hd
    >>| Option.map ~f:Row.to_alist
  in
  ae_sexp [%sexp_of: (string * string) list option] (Some ["id", "1"]) res

let test_prevent_transaction_deadlock () =
  let expect = "Attempted to use outer DB handle inside of \
                with_transaction. This would have lead to a deadlock."
  in
  Mssql.Test.with_conn @@ fun db ->
  Mssql.with_transaction db (fun _ ->
    Monitor.try_with_or_error (fun () ->
      Mssql.execute_unit db "WAITFOR DELAY '00:00:00'")
    >>| function
    | Error err ->
      Error.to_string_mach err
      |> String.is_substring ~substring:expect
      |> assert_bool (sprintf "Expected exception containing %s but got %s"
                        expect (Error.to_string_mach err))
    | _ -> assert false)

let () =
  [ "select and convert", test_select_and_convert
  ; "multiple queries in execute", test_multiple_queries_in_execute
  ; "multiple queries in execute_multi_result",
    test_multiple_queries_in_execute_multi_result
  ; "execute_unit", test_execute_unit
  ; "execute_unit fail", test_execute_unit_fail
  ; "execute_single", test_execute_single
  ; "execute_single fail", test_execute_single_fail
  ; "test list order", test_order
  ; "test params", test_param_parsing
  ; "test param out of range", test_param_out_of_range
  ; "test execute many", test_execute_many
  ; "test concurrent queries", test_concurrent_queries
  ; "test connection pool concurrency", test_connection_pool_concurrency
  ; "test rollback", test_rollback
  ; "test auto rollback", test_auto_rollback
  ; "test commit", test_commit
  ; "test auto commit", test_auto_commit
  ; "test other execute during transaction", test_other_execute_during_transaction
  ; "test prevent transaction deadlock", test_prevent_transaction_deadlock ]
  @ round_trip_tests
  @ recoding_tests
  |> List.map ~f:(fun (name, f) ->
    name >:: (fun ctx ->
      try
        async_test ctx @@ fun () ->
        f ()
      with exn ->
        Monitor.extract_exn exn
        |> raise))
  |> test_list
  |> run_test_tt_main

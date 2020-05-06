open Core

let params =
  lazy
    ([ "MSSQL_TEST_SERVER"
     ; "MSSQL_TEST_DATABASE"
     ; "MSSQL_TEST_USERNAME"
     ; "MSSQL_TEST_PASSWORD"
     ; "MSSQL_TEST_PORT"
     ]
    |> List.map ~f:Sys.getenv
    |> function
    | [ Some host; Some db; Some user; Some password; port ] ->
      host, db, user, password, Option.map ~f:Int.of_string port
    | _ -> failwith "MSSQL_TEST_* environment not set")
;;

let with_conn f =
  let host, db, user, password, port = Lazy.force params in
  Client.with_conn ~host ~db ~user ~password ?port f
;;

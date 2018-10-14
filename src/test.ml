open Core

let params =
  lazy (
    [ "MSSQL_TEST_SERVER"
    ; "MSSQL_TEST_DATABASE"
    ; "MSSQL_TEST_USERNAME"
    ; "MSSQL_TEST_PASSWORD" ]
    |> List.map ~f:Sys.getenv
    |> function
    | [ Some host ; Some db ; Some user ; Some password ] ->
      host, db, user, password
    | _ -> raise (OUnitTest.Skip "MSSQL_TEST_* environment not set"))

let with_conn f =
  let host, db, user, password = Lazy.force params in
  Client.with_conn ~host ~db ~user ~password f

let with_pool ?max_connections f =
  let host, db, user, password = Lazy.force params in
  Client.Pool.with_pool ~host ~db ~user ~password ?max_connections f


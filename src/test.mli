(** Exposes functions to help with tests that use Mssql *)
open Async_kernel

(** Mssql db connection with test credentials *)
val with_conn : (Client.t -> 'a Deferred.t) -> 'a Deferred.t

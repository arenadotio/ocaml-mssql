open Core
open Freetds

type t =
  | Bignum of Bignum.t
  | Bool of bool
  | Float of float
  | Int of int
  | Int32 of int32
  | Int64 of int64
  | String of string
  | Date of Time.t
[@@deriving sexp]

let recode ~src ~dst str =
  (* Need to convert from CP1252 since SQL Server can't handle UTF-8 in any
     reasonable way.
     Note that //TRANSLIT means we will try to convert between similar
     characters in the two encodings and use ? if necessary instead of
     erroring out.

     However, it can still error out in really wrong cases, which //IGNORE
     doesn't fix either, so in that case we'll log the offending string and do a
     simple ascii filter. *)
  try
    let dst = sprintf "%s//TRANSLIT" dst in
    Encoding.recode_string ~src ~dst str
  with exn ->
    Logger.info !"Recoding error, falling back to ascii filter %{sexp: exn} %s"
      exn str;
    String.filter str ~f:(fun c -> Char.to_int c < 128)

let date_of_string s =
  [ Date.of_string
  ; Fn.compose
      Time.(to_date ~zone:Zone.utc)
      Time.(of_string_gen ~if_no_timezone:(`Use_this_one Zone.utc)) ]
  |> List.find_map ~f:(fun f ->
    Option.try_with (fun () -> f s))
  |> function
  | Some d -> d
  | None ->
    failwithf "Unable to parse datetime %s" s ()

let datetime_of_string s =
  [ Time.(of_string_gen ~if_no_timezone:(`Use_this_one Zone.utc))
  ; Fn.compose
      (Fn.flip Time.(of_date_ofday ~zone:Zone.utc) Time.Ofday.start_of_day)
      Date.of_string ]
  |> List.find_map ~f:(fun f ->
    Option.try_with (fun () -> f s))
  |> function
  | Some d -> d
  | None ->
    failwithf "Unable to parse datetime %s" s ()

let of_data ~(month_offset:int) (data:Ct.sql_t) =
  ignore month_offset;
  match data with
  | `Bit b -> Some (Bool b)
  | `Int i -> Some (Int32 i)
  | `Smallint i
  | `Tinyint i -> Some (Int i)
  | `Float f -> Some (Float f)
  | `Decimal s ->
    Some (Bignum (Bignum.of_string s))
  | `Binary s -> Some (String s)
  | `Text s
  | `String s ->
    Some (String (recode ~src:"CP1252" ~dst:"UTF-8" s))
  | `Datetime s ->
    let d = datetime_of_string s in
    Some (Date d)
  | `Null -> None

let to_string ~quote_string =
  function
  | None -> "NULL"
  | Some p ->
    match p with
    | Bignum n -> Bignum.to_string_hum n |> quote_string
    | Bool b -> if b then "1" else "0"
    | Float f -> Float.to_string f
    | Int i -> Int.to_string i
    | Int32 i -> Int32.to_string i
    | Int64 i -> Int64.to_string i
    | String s -> s |> quote_string
    | Date t ->
      Time.format ~zone:Time.Zone.utc t "%Y-%m-%dT%H:%M:%S" |> quote_string

let to_string_escaped =
  (* Quote the string by replacing ' with '' and null with CHAR(0). This
     is somewhat complicated because I couldn't find a way to escape a
     null character without closing the string and adding +CHAR(0)+.
     I couldn't do this with String.concat since that would force us to
     concat every CHAR, which is inefficient (i.e. "asdf" would be passed as
     'a'+'s'+'d'+'f'). *)
  let quote_string s =
    (* Need to convert to CP1252 since SQL Server can't handle UTF-8 in any
       reasonable way. *)
    let s = recode ~src:"UTF-8" ~dst:"CP1252" s in
    (* len * 2 will always hold the resulting string unless it has null
       chars, so this should make the standard case fast without wasting much
       memory. *)
    let buf = Buffer.create ((String.length s) * 2) in
    let in_str = ref false in
    let first = ref true in
    for i = 0 to String.length s - 1 do
      let c = String.get s i in
      if c = '\x00' then begin
        if !in_str then begin
          Buffer.add_char buf '\'';
          in_str := false;
        end;
        if not !first then
          Buffer.add_char buf '+';
        Buffer.add_string buf "CHAR(0)"
      end
      else begin
        if not !in_str then begin
          if not !first then
            Buffer.add_char buf '+';
          Buffer.add_char buf '\'';
          in_str := true;
        end;
        if c = '\'' then
          Buffer.add_string buf "''"
        else
          Buffer.add_char buf c;
      end;
      first := false;
    done;
    if !first then begin
      Buffer.add_char buf '\'';
      in_str := true
    end;
    if !in_str then
      Buffer.add_char buf '\'';
    Buffer.contents buf
  in
  to_string ~quote_string

let to_string = to_string ~quote_string:Fn.id

let with_error_msg ?column ~f type_name t =
  try
    f t
  with Assert_failure _ ->
    let column_info = match column with
      | None -> ""
      | Some column -> sprintf " column %s" column
    in
    failwithf !"Failed to convert%s %{sexp: t} to type %s"
      column_info t type_name ()

let bignum ?column =
  with_error_msg ?column "float" ~f:(function
    | Bignum b -> b
    | Float f -> Bignum.of_float_dyadic f
    | Int i -> Bignum.of_int i
    | Int32 i -> Int.of_int32_exn i |> Bignum.of_int
    | Int64 i -> Int64.to_string i |> Bignum.of_string
    | _ -> assert false)

let float ?column =
  with_error_msg ?column "float" ~f:(function
    | Bignum b -> Bignum.to_float b
    | Float f -> f
    | Int i -> Float.of_int i
    | Int32 i -> Int.of_int32_exn i |> Float.of_int
    | Int64 i -> Float.of_int64 i
    | _ -> assert false)

let int ?column =
  with_error_msg ?column "int" ~f:(function
    | Bignum b -> Bignum.to_int_exn b
    | Bool false -> 0
    | Bool true -> 1
    | Float f -> Int.of_float f
    | Int i -> i
    | Int32 i -> Int32.to_int_exn i
    | Int64 i -> Int64.to_int_exn i
    | _ -> assert false)

let int32 ?column =
  with_error_msg ?column "int32" ~f:(function
    | Bignum b -> Bignum.to_int_exn b |> Int32.of_int_exn
    | Bool false -> Int32.zero
    | Bool true -> Int32.one
    | Float f -> Int32.of_float f
    | Int i -> Int32.of_int_exn i
    | Int32 i -> i
    | _ -> assert false)

let int64 ?column =
  with_error_msg ?column "int64" ~f:(function
    | Bignum b -> Bignum.to_int_exn b |> Int64.of_int_exn
    | Bool false -> Int64.zero
    | Bool true -> Int64.one
    | Float f -> Int64.of_float f
    | Int i -> Int64.of_int i
    | Int32 i -> Int64.of_int32 i
    | Int64 i -> i
    | _ -> assert false)

let bool ?column =
  with_error_msg ?column "bool" ~f:(function
    | Bool b -> b
    (* MSSQL's native BIT type is 0 or 1, so conversions from 0 or 1 ints
       make sense *)
    | Int i when i = 0 -> false
    | Int i when i = 1 -> true
    | Int32 i when i = Int32.zero -> false
    | Int32 i when i = Int32.one -> true
    | Int64 i when i = Int64.zero -> false
    | Int64 i when i = Int64.one -> true
    | _ -> assert false)

let str ?column =
  with_error_msg ?column "string" ~f:(function
    | Bignum b -> Bignum.to_string_hum b
    | Bool b -> Bool.to_string b
    | Float f -> Float.to_string f
    | Int i -> Int.to_string i
    | Int32 i -> Int32.to_string i
    | Int64 i -> Int64.to_string i
    | String s -> s
    | Date t -> Time.to_string_abs ~zone:Time.Zone.utc t)

let date ?column =
  with_error_msg ?column "date" ~f:(function
    | Date d -> Date.of_time ~zone:Time.Zone.utc d
    | String s ->
      (* For datetimes, return the date part, for just dates parse it alone *)
      begin try
        datetime_of_string s
        |> Time.to_date ~zone:Time.Zone.utc
      with Failure _ ->
        date_of_string s
      end
    | _ -> assert false)

let datetime ?column =
  with_error_msg ?column "datetime" ~f:(function
    | Date d -> d
    | String s ->
      datetime_of_string s
    | _ -> assert false)

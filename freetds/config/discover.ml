open Printf
module C = Configurator.V1

let conf c =
  let cflags = [] in
  let libs = ["-lct"; "-lsybdb"] in
  let reg_row =
    let open C.C_define in
    let h = import c ~includes:["sybdb.h"] [("REG_ROW", Type.Int)] in
    match List.assoc "REG_ROW" h with
    | Value.Int r -> r
    | Value.Switch _ | Value.String _ -> assert false
    | exception _ ->
       C.die "The value of REG_ROW was not found in the C hreader file. \
              Please make sure the development files of FreeTDS are \
              installed in a location where the C compiler finds them." in
  let ocaml_ver = C.ocaml_config_var_exn c "version" in
  let major, minor = Scanf.sscanf ocaml_ver "%d.%d" (fun m n -> m, n) in
  let cflags = if major > 4 || (major = 4 && minor >= 6) then
                 "-DOCAML406" :: cflags
                 else cflags in
  let fh = open_out "reg_row.txt" in
  fprintf fh "%d" reg_row;
  close_out fh;
  C.Flags.write_sexp "c_flags.sexp" cflags;
  C.Flags.write_sexp "c_library_flags.sexp" libs

let () =
  C.main ~name:"freetds" conf


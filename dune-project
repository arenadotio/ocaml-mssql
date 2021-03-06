(lang dune 1.11)

(using fmt 1.1)

(name mssql)

(generate_opam_files true)

(license "Apache-2.0")

(maintainers "Arena Developers <silver-snakes@arena.io>")

(authors "Arena Developers <silver-snakes@arena.io>")

(documentation "https://arenadotio.github.io/ocaml-mssql")

(source
 (github arenadotio/ocaml-mssql))

(package
 (name mssql)
 (synopsis "Async SQL Server client using FreeTDS")
 (description
   "Mssql wraps FreeTDS in a nicer and safer interface, with support for parameterized queries, thread-based async IO, and a thread pool.")
 (depends
  (alcotest
   (and
    :with-test
    (>= 1.0.1)))
  (alcotest-async
   (and
    :with-test
    (>= 1.0.1)))
  async_unix
  bignum
  ppx_jane
  (iter
   (>= 1.2))
  (ocaml
   (>= 4.06.1))
  (odoc :with-doc)
  logs
  (text
   (>= 0.8.0))
  (freetds
   (>= 0.7))
  (bisect_ppx
   (and
    :dev
    (>= 2.0.0)))
  (dune
   (>= 1.11))))

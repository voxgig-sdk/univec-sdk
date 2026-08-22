(* Test entry point: prints the pass/fail summary and exits non-zero on any
 * failure. Linked LAST so every test module's top-level registrations have
 * already run. *)

let () = Testutil.summary ()

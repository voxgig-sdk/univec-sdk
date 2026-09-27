/*
 * The wall clock behind `@[extern "sekreto_epoch_seconds"]` in the vendored
 * SekretoPlugins.Clock: seconds since the Unix epoch, for the SigV4 stamp
 * the aws plugin group signs. libc only - it is kept apart from
 * sekreto_curl.c so that file stays the one place naming a library outside
 * the toolchain. Why it is sdkgen's own source rather than a vendored copy
 * of upstream's lean/ffi/sekreto_clock.c is explained at the top of
 * sekreto_curl.c.
 */

#include <lean/lean.h>

#include <time.h>

LEAN_EXPORT lean_obj_res sekreto_epoch_seconds(lean_obj_arg world) {
  (void)world;
  return lean_io_result_mk_ok(lean_box_uint64((uint64_t)time(NULL)));
}

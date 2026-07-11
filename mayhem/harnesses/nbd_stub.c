/*
 * mayhem/harnesses/nbd_stub.c — additive link shim.
 *
 * rauc's src/polling.c (always compiled) references R_NBD_ERROR / r_nbd_error_quark(),
 * but the definition lives in src/nbd.c which meson ONLY compiles when -Dstreaming=true.
 * The OSS-Fuzz / mayhem build keeps streaming (and its libcurl + libnl-genl + nbd-netlink.h
 * dependency chain) OFF, so the manifest/bundle fuzzers fail to link with one undefined
 * symbol: r_nbd_error_quark. We don't touch any upstream file — we provide the quark here,
 * byte-identical to src/nbd.c's definition. The R_NBD_ERROR_* enum values are header-only
 * (include/nbd.h), so no other symbol is needed.
 */
#include <glib.h>

GQuark r_nbd_error_quark(void)
{
	return g_quark_from_static_string("r-nbd-error-quark");
}

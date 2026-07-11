/*
 * mayhem/harnesses/manifest_oracle.c — self-contained golden oracle over the fuzzed
 * manifest-parse path (load_manifest_mem, the exact entry the manifest_fuzzer drives).
 *
 * rauc's full meson suite needs root + loopback mounts (bundle/install/dm/signature tests),
 * so we can't run it at image-build time. Instead this is a small known-answer oracle on the
 * GKeyFile manifest parser: it parses a well-formed RAUC manifest and asserts the decoded
 * fields (compatible / version / bundle format / images), then asserts a malformed manifest
 * (mandatory `compatible` missing — the same case as test/broken-manifest.raucm) is REJECTED.
 * A no-op / "return TRUE" patch to the parser cannot pass: the accept case checks concrete
 * field values AND the reject case requires a hard parse failure.
 *
 * Linked against the sanitized librauc.a (so the oracle exercises the instrumented parser).
 * No libFuzzer runtime. exit 0 iff every assertion holds.
 */
#include <glib.h>
#include <string.h>
#include <manifest.h>

static const char *GOOD =
	"[update]\n"
	"compatible=Test Config\n"
	"version=2011.03-2\n"
	"\n"
	"[bundle]\n"
	"format=verity\n"
	"\n"
	"[image.rootfs]\n"
	"filename=rootfs.img\n"
	"\n"
	"[image.appfs]\n"
	"filename=appfs.img\n";

/* mandatory `compatible` missing under [update] — must fail to parse (R_MANIFEST_ERROR_COMPATIBLE) */
static const char *BAD =
	"[update]\n"
	"# compatible missing here!\n"
	"\n"
	"[image.foo]\n"
	"bar=bazz\n";

static int g_pass = 0, g_fail = 0;
#define CHECK(cond, msg) do { \
	if (cond) { g_pass++; } \
	else { g_fail++; g_printerr("FAIL: %s\n", msg); } \
} while (0)

int main(void)
{
	/* ACCEPT: well-formed manifest parses and decodes to the expected fields */
	{
		g_autoptr(GBytes) b = g_bytes_new_static(GOOD, strlen(GOOD));
		g_autoptr(RaucManifest) rm = NULL;
		g_autoptr(GError) error = NULL;
		gboolean ok = load_manifest_mem(b, &rm, &error);
		CHECK(ok && rm != NULL, "good manifest should parse");
		if (ok && rm != NULL) {
			CHECK(g_strcmp0(rm->update_compatible, "Test Config") == 0, "update_compatible == 'Test Config'");
			CHECK(g_strcmp0(rm->update_version, "2011.03-2") == 0, "update_version == '2011.03-2'");
			CHECK(rm->bundle_format == R_MANIFEST_FORMAT_VERITY, "bundle_format == verity");
			CHECK(rm->images != NULL && g_list_length(rm->images) == 2, "manifest has two images");
			if (rm->images != NULL) {
				RaucImage *img = rm->images->data;
				CHECK(img != NULL && g_strcmp0(img->filename, "rootfs.img") == 0, "first image filename == 'rootfs.img'");
			}
		}
	}

	/* REJECT: missing mandatory `compatible` must be a hard parse failure */
	{
		g_autoptr(GBytes) b = g_bytes_new_static(BAD, strlen(BAD));
		g_autoptr(RaucManifest) rm = NULL;
		g_autoptr(GError) error = NULL;
		gboolean ok = load_manifest_mem(b, &rm, &error);
		CHECK(!ok, "malformed manifest (no compatible) must be rejected");
	}

	g_print("ORACLE passed=%d failed=%d\n", g_pass, g_fail);
	return g_fail ? 1 : 0;
}

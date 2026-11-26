#!/usr/bin/env bash
set -euo pipefail

# Run the driver's actual quirk table and calculations without a real camera.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$repo/module/ov02c10.c"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int64_t s64;
enum { DMI_SYS_VENDOR, DMI_PRODUCT_NAME, DMI_BOARD_NAME };
struct match { int key; const char *value; };
struct dmi_system_id { struct match matches[4]; };
#define DMI_EXACT_MATCH(k, v) { k, v }
static const char *actual[3];
static bool dmi_check_system(const struct dmi_system_id *table) {
	for (; table->matches[0].value; ++table) {
		size_t i = 0;
		while (table->matches[i].value &&
		       !strcmp(table->matches[i].value, actual[table->matches[i].key])) ++i;
		if (!table->matches[i].value) return true;
	}
	return false;
}
struct ov02c10 { s64 actual_link_freqs[1]; };
struct ov02c10_mode { u32 link_freq_index; u8 mipi_lanes; };
C
awk '/^#define OV02C10_(MCLK_26MHZ|RGB_DEPTH)[[:space:]]/ { print }
     /^static const struct dmi_system_id ov02c10_26mhz_quirks\[\]/,/^};$/ { print }' "$src"
for fn in needs_26mhz_timing clock_scaled get_pixel_rate; do
	awk -v fn="ov02c10_${fn}(" 'index($0, fn) && /^static / { found=1 } found { print } found && /^}$/ { exit }' "$src"
done
cat <<'C'
static void check(u32 clock, u8 lanes, bool expected,
		  u32 link, u32 pix, u32 vts) {
	const bool scaled = ov02c10_needs_26mhz_timing(clock, lanes);
	struct ov02c10 dev = { { ov02c10_clock_scaled(400000000, scaled) } };
	struct ov02c10_mode mode = { 0, lanes };
	assert(scaled == expected);
	assert(dev.actual_link_freqs[0] == link);
	assert(ov02c10_get_pixel_rate(&dev, &mode) == pix);
	assert(ov02c10_clock_scaled(lanes == 2 ? 2328 : 1164, scaled) == vts);
}
int main(void) {
	actual[DMI_SYS_VENDOR] = "SAMSUNG ELECTRONICS CO., LTD.";
	actual[DMI_PRODUCT_NAME] = "960XGL";
	actual[DMI_BOARD_NAME] = "NP960XGL-XG1BR";
	check(26000000, 2, true, 541666666, 216666666, 3152);
	check(19200000, 2, false, 400000000, 160000000, 2328);
	check(26000000, 1, false, 400000000, 80000000, 1164);
	check(24000000, 2, false, 400000000, 160000000, 2328);
	actual[DMI_BOARD_NAME] = "NP960XGL-XG1BR-other";
	check(26000000, 2, false, 400000000, 160000000, 2328);
	actual[DMI_BOARD_NAME] = "NP960XGL-XG1BR";
	actual[DMI_SYS_VENDOR] = "other";
	check(26000000, 2, false, 400000000, 160000000, 2328);
	return 0;
}
C
} | gcc -std=c11 -Wall -Werror -x c -o "$test_dir/test-timing" -
"$test_dir/test-timing"
printf '%s\n' 'test-sensor-timing: ok'

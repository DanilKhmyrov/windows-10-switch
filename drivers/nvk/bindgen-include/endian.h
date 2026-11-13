/* endian.h for bindgen only. Meson finds endian.h in LLVM-MinGW's clang 23 resource headers,
 * but bindgen parses with Ubuntu's libclang 18, which has none. Windows on ARM64 is little
 * endian; these are the names Mesa's util/u_endian.h checks. */
#ifndef SWITCH_WP_BINDGEN_ENDIAN_H
#define SWITCH_WP_BINDGEN_ENDIAN_H
#define __LITTLE_ENDIAN 1234
#define __BIG_ENDIAN 4321
#define __BYTE_ORDER __LITTLE_ENDIAN
#define LITTLE_ENDIAN __LITTLE_ENDIAN
#define BIG_ENDIAN __BIG_ENDIAN
#define BYTE_ORDER __BYTE_ORDER
#endif

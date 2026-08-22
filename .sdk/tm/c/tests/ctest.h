// Minimal C test harness for the Univec SDK test binaries. Each test
// file #includes this and "api.h", runs checks via CHECK/CHECK_EQ_STR/etc.,
// and ends its main() with TEST_SUMMARY(name) which prints a
// "<name>: N checks, M failed" line and returns non-zero on any failure.

#ifndef PROJECTNAME_CTEST_H
#define PROJECTNAME_CTEST_H

#include "api.h"

#include <stdio.h>
#include <string.h>

static int CT_CHECKS = 0;
static int CT_FAILS = 0;

#define CHECK(cond, msg)                                                        \
  do {                                                                         \
    CT_CHECKS++;                                                               \
    if (!(cond)) {                                                             \
      CT_FAILS++;                                                              \
      fprintf(stderr, "FAIL [%s:%d]: %s\n", __FILE__, __LINE__, (msg));        \
    }                                                                          \
  } while (0)

#define CHECK_TRUE(cond) CHECK((cond), #cond)

#define CHECK_STR_EQ(got, want, msg)                                            \
  do {                                                                         \
    CT_CHECKS++;                                                               \
    const char* _g = (got);                                                   \
    const char* _w = (want);                                                  \
    if (!_g || !_w || strcmp(_g, _w) != 0) {                                   \
      CT_FAILS++;                                                              \
      fprintf(stderr, "FAIL [%s:%d]: %s (got '%s' want '%s')\n", __FILE__,     \
              __LINE__, (msg), _g ? _g : "(null)", _w ? _w : "(null)");        \
    }                                                                          \
  } while (0)

#define CHECK_INT_EQ(got, want, msg)                                           \
  do {                                                                         \
    CT_CHECKS++;                                                               \
    long long _g = (long long)(got);                                          \
    long long _w = (long long)(want);                                         \
    if (_g != _w) {                                                           \
      CT_FAILS++;                                                              \
      fprintf(stderr, "FAIL [%s:%d]: %s (got %lld want %lld)\n", __FILE__,     \
              __LINE__, (msg), _g, _w);                                        \
    }                                                                          \
  } while (0)

#define TEST_SUMMARY(name)                                                     \
  do {                                                                         \
    printf("%s: %d checks, %d failed\n", (name), CT_CHECKS, CT_FAILS);         \
    return CT_FAILS == 0 ? 0 : 1;                                             \
  } while (0)

#endif // PROJECTNAME_CTEST_H

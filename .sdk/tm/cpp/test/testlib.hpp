// Univec SDK — minimal test harness (green-bar style; no framework).
// Each test/*.cpp includes this, defines test functions, RUN()s them from
// main() and returns summary(). ASSERT_* record failures (they do not abort)
// so all checks in a run are reported.

#ifndef SDK_TEST_TESTLIB_HPP
#define SDK_TEST_TESTLIB_HPP

#include <iostream>
#include <sstream>
#include <string>

#include "../core/sdk.hpp"

namespace sdktest {

inline int& fails() { static int f = 0; return f; }
inline int& checks() { static int c = 0; return c; }
inline int& tests() { static int t = 0; return t; }

inline void record_fail(const std::string& where, const std::string& msg) {
  fails()++;
  std::cerr << "  FAIL [" << where << "]: " << msg << "\n";
}

inline std::string vstr(const sdk::Value& v) { return sdk::vs::jsonify(v, 0); }

inline void expect_true(bool cond, const std::string& where, const std::string& msg) {
  checks()++;
  if (!cond) record_fail(where, msg);
}

template <typename A, typename B>
inline void expect_eq(const A& a, const B& b, const std::string& where, const std::string& msg) {
  checks()++;
  if (!(a == b)) {
    std::ostringstream oss;
    oss << msg << " (got " << a << ", want " << b << ")";
    record_fail(where, oss.str());
  }
}

inline void expect_eq_val(const sdk::Value& a, const sdk::Value& b, const std::string& where,
                          const std::string& msg) {
  checks()++;
  if (!(a == b)) {
    record_fail(where, msg + " (got " + vstr(a) + ", want " + vstr(b) + ")");
  }
}

inline int summary(const std::string& name) {
  std::cout << name << ": " << tests() << " tests, " << checks() << " checks, " << fails()
            << " failures\n";
  return fails() > 0 ? 1 : 0;
}

} // namespace sdktest

// Run a void() test function, catching escaped exceptions as failures.
#define T_RUN(fn)                                                                                  \
  do {                                                                                             \
    sdktest::tests()++;                                                                            \
    try {                                                                                          \
      fn();                                                                                        \
    } catch (const sdk::SdkErrorPtr& e) {                                                          \
      sdktest::record_fail(#fn, std::string("uncaught SdkError: ") + e->msg);                      \
    } catch (const std::exception& e) {                                                            \
      sdktest::record_fail(#fn, std::string("uncaught exception: ") + e.what());                   \
    } catch (...) {                                                                                \
      sdktest::record_fail(#fn, "uncaught unknown exception");                                     \
    }                                                                                              \
  } while (0)

#define ASSERT_TRUE(cond, msg) sdktest::expect_true((cond), __func__, (msg))
#define ASSERT_FALSE(cond, msg) sdktest::expect_true(!(cond), __func__, (msg))
#define ASSERT_EQ(a, b, msg) sdktest::expect_eq((a), (b), __func__, (msg))
#define ASSERT_EQ_VAL(a, b, msg) sdktest::expect_eq_val((a), (b), __func__, (msg))
#define ASSERT_NOTNULL(p, msg) sdktest::expect_true((bool)(p), __func__, (msg))
#define ASSERT_NULL(p, msg) sdktest::expect_true(!(bool)(p), __func__, (msg))
#define ASSERT_NOVAL(v, msg) sdktest::expect_true(!(v).is_undef(), __func__, (msg))

#endif // SDK_TEST_TESTLIB_HPP

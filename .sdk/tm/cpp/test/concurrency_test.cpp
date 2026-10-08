// Univec SDK - requests in flight at once on one client. Each resolves
// its operation through the cache the client's root context shares with
// every request, and registers and cleans secrets through the one registry
// the client holds.

#include "testlib.hpp"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

using namespace sdk;

// PROJECTENV_TEST_CONCURRENCY_ROUNDS sets the rounds: fewer where each costs
// more, as under ThreadSanitizer.
static int envRounds() {
  const char* set = std::getenv("PROJECTENV_TEST_CONCURRENCY_ROUNDS");
  int rounds = nullptr == set ? 0 : std::atoi(set);
  return 0 < rounds ? rounds : 200;
}

static const int ROUNDS = envRounds();
static const int QUARTER = std::max(1, ROUNDS / 4);
static const int WIDTH = 8;
static const int OPS = 32;

static const std::string BASIC_USER = "CONCURRENCY-BASIC-USER";
static const std::string BASIC_PASS = "CONCURRENCY-BASIC-PASS";

static Value liveOptions() {
  return vmap({{"base", Value(std::string("http://concurrency.test/api"))},
               {"allow", vmap({{"op", Value(std::string("direct"))}})}});
}

// A live client whose transport answers at once, showing `seen` the headers
// of each request.
static std::shared_ptr<UnivecSDK> liveClient(
    const Value& options = liveOptions(), std::function<void(const Value&)> seen = nullptr) {
  auto client = std::make_shared<UnivecSDK>(options);
  // Through the base: an entity accessor may share the member's name.
  SdkClient& base = *client;
  base.utility->fetcher = [seen](CtxPtr, const std::string&, const Value& fetchdef) -> Value {
    if (seen) seen(getp(fetchdef, "headers"));
    vs::Injector json = [](vs::Injection&, const Value&, const std::string&, const Value&) -> Value {
      return vmap({{"ok", Value(true)}});
    };
    return vmap({{"status", Value(200)}, {"statusText", Value(std::string("OK"))},
                 {"headers", vmap()}, {"json", Value(json)}});
  };
  return client;
}

// Runs body on WIDTH threads released together, and returns what they threw.
template <typename F>
static std::vector<std::string> atOnce(F body) {
  std::atomic<int> ready{0};
  std::mutex mu;
  std::vector<std::string> thrown;
  std::vector<std::thread> threads;
  for (int n = 0; n < WIDTH; n++) {
    threads.emplace_back([&, n]() {
      ready.fetch_add(1);
      while (ready.load() < WIDTH) std::this_thread::yield();
      try {
        body(n);
      } catch (const SdkErrorPtr& e) {
        std::lock_guard<std::mutex> lk(mu);
        thrown.push_back(e->msg);
      } catch (const std::exception& e) {
        std::lock_guard<std::mutex> lk(mu);
        thrown.push_back(e.what());
      }
    });
  }
  for (auto& t : threads) t.join();
  return thrown;
}

static void concurrent_first_requests_succeed() {
  for (int round = 0; round < ROUNDS; round++) {
    // A fresh client each round, so every request in it is a first request.
    auto client = liveClient();
    std::vector<Value> results(WIDTH);
    auto thrown = atOnce([&](int n) {
      results[n] = client->direct(vmap({{"path", Value("p" + std::to_string(n))}}));
    });
    if (!thrown.empty()) {
      ASSERT_TRUE(false, "round " + std::to_string(round) + " threw: " + thrown[0]);
      return;
    }
    for (int n = 0; n < WIDTH; n++) {
      if (!is_true(getp(results[n], "ok"))) {
        ASSERT_TRUE(false, "round " + std::to_string(round) + ", request " + std::to_string(n) +
                    " failed: " + sdktest::vstr(results[n]));
        return;
      }
    }
  }
  ASSERT_TRUE(true, "every request succeeded");
}

static void concurrent_resolutions_share_one_cached_operation() {
  for (int round = 0; round < ROUNDS; round++) {
    auto client = liveClient();
    auto utility = client->getUtility();
    auto root = client->getRootCtx();
    std::vector<std::vector<OperationPtr>> ops(WIDTH, std::vector<OperationPtr>(OPS));
    auto resolve = [&](int k) {
      CtxSpec cs;
      cs.setOpname("op" + std::to_string(k));
      return utility->makeContext(cs, root)->op;
    };
    auto thrown = atOnce([&](int n) {
      for (int k = 0; k < OPS; k++) ops[n][k] = resolve(k);
    });
    if (!thrown.empty()) {
      ASSERT_TRUE(false, "round " + std::to_string(round) + " threw: " + thrown[0]);
      return;
    }
    for (int k = 0; k < OPS; k++) {
      OperationPtr cached = resolve(k);
      for (int n = 0; n < WIDTH; n++) {
        if (ops[n][k] != cached) {
          ASSERT_TRUE(false, "round " + std::to_string(round) + ": op" + std::to_string(k) +
                      " resolved to more than one Operation");
          return;
        }
      }
    }
  }
  ASSERT_TRUE(true, "every operation resolved to one cached Operation");
}

// The k-th secret registering thread n adds in round r.
static std::string addedSecret(const std::string& r, int n, int k) {
  return "ADDED-SECRET-" + r + "-" + std::to_string(n) + "-" + std::to_string(k);
}

// Registers thread n's secrets, then counts the thread out of `left`.
static void registerSecrets(UtilityPtr utility, CtxPtr root, const std::string& r, int n,
                            std::atomic<int>& left) {
  struct Done {
    std::atomic<int>& left;
    ~Done() { left.fetch_sub(1); }
  } done{left};
  for (int k = 0; k < OPS; k++) utility->cleanAdd(root, Value(addedSecret(r, n, k)));
}

// The first of `known` and the secrets `registrars` threads registered in
// round r that a clean leaves raw, or "".
static std::string unmaskedSecret(UtilityPtr utility, CtxPtr root, const std::string& r,
                                  int registrars, std::vector<std::string> known = {}) {
  for (int n = 0; n < registrars; n++) {
    for (int k = 0; k < OPS; k++) known.push_back(addedSecret(r, n, k));
  }
  for (const auto& secret : known) {
    Value got = utility->clean(root, Value(secret));
    if (!got.is_string() || "[redacted]" != got.as_string()) return secret;
  }
  return "";
}

// Secrets registered on some threads while others clean: every clean masks
// what was registered before it, the longer secret whole, and no
// registration is lost.
static void concurrent_registration_keeps_every_secret_masked() {
  const std::string masked = "a [redacted] b [redacted] c";
  for (int round = 0; round < QUARTER; round++) {
    auto client = liveClient();
    auto utility = client->getUtility();
    auto root = client->getRootCtx();
    std::string r = std::to_string(round);
    std::string inner = "INNER-SECRET-" + r;
    utility->cleanAdd(root, Value(inner));
    utility->cleanAdd(root, Value("OUTER-" + inner + "-TAIL"));
    Value text("a " + inner + " b OUTER-" + inner + "-TAIL c");
    Value before = utility->clean(root, text);
    if (!before.is_string() || masked != before.as_string()) {
      ASSERT_TRUE(false, "round " + r + " cleaned to: " + sdktest::vstr(before));
      return;
    }

    std::atomic<int> registering{WIDTH / 2};
    std::mutex mu;
    std::vector<std::string> wrong;
    auto thrown = atOnce([&](int n) {
      if (n < WIDTH / 2) {
        registerSecrets(utility, root, r, n, registering);
        return;
      }
      while (0 < registering.load()) {
        Value got = utility->clean(root, text);
        if (!got.is_string() || masked != got.as_string()) {
          std::lock_guard<std::mutex> lk(mu);
          wrong.push_back(sdktest::vstr(got));
          return;
        }
      }
    });
    if (!thrown.empty()) {
      ASSERT_TRUE(false, "round " + r + " threw: " + thrown[0]);
      return;
    }
    if (!wrong.empty()) {
      ASSERT_TRUE(false, "round " + r + " cleaned to: " + wrong[0]);
      return;
    }
    std::string raw = unmaskedSecret(utility, root, r, WIDTH / 2);
    if (!raw.empty()) {
      ASSERT_TRUE(false, "round " + r + ": " + raw + " was registered but not masked");
      return;
    }
  }
  ASSERT_TRUE(true, "every secret stayed masked");
}

// Requests on one client while secrets register on it: each request copies
// the client's options, the registry among them.
static void concurrent_requests_survive_registration() {
  for (int round = 0; round < QUARTER; round++) {
    auto client = liveClient();
    auto utility = client->getUtility();
    auto root = client->getRootCtx();
    std::string r = std::to_string(round);
    std::atomic<int> registering{WIDTH / 2};
    std::mutex mu;
    std::vector<std::string> failed;
    auto thrown = atOnce([&](int n) {
      if (n < WIDTH / 2) {
        registerSecrets(utility, root, r, n, registering);
        return;
      }
      while (0 < registering.load()) {
        Value got = client->direct(vmap({{"path", Value("p" + std::to_string(n))}}));
        if (!is_true(getp(got, "ok"))) {
          std::lock_guard<std::mutex> lk(mu);
          failed.push_back(sdktest::vstr(got));
          return;
        }
      }
    });
    if (!thrown.empty()) {
      ASSERT_TRUE(false, "round " + r + " threw: " + thrown[0]);
      return;
    }
    if (!failed.empty()) {
      ASSERT_TRUE(false, "round " + r + ", a request failed: " + failed[0]);
      return;
    }
    std::string raw = unmaskedSecret(utility, root, r, WIDTH / 2);
    if (!raw.empty()) {
      ASSERT_TRUE(false, "round " + r + ": " + raw + " was registered but not masked");
      return;
    }
  }
  ASSERT_TRUE(true, "every request succeeded while secrets registered");
}

// Whether a header value holds `text`.
static bool carries(const Value& headers, const std::string& text) {
  if (!headers.is_map()) return false;
  for (const auto& kv : *headers.as_map()) {
    if (kv.second.is_string() && std::string::npos != kv.second.as_string().find(text)) return true;
  }
  return false;
}

// First requests on a client carrying Basic credentials while secrets
// register on it: where the API takes HTTP Basic, prepareAuth registers the
// encoded pair as the other requests copy the options.
static void concurrent_basic_requests_survive_registration() {
  const std::string pair = util::cleanBase64(BASIC_USER + ":" + BASIC_PASS);
  int sent = 0;
  int paired = 0;
  for (int round = 0; round < QUARTER; round++) {
    std::atomic<int> roundSent{0};
    std::atomic<int> roundPaired{0};
    Value options = liveOptions();
    map_put(options, "apikey", Value(BASIC_USER));
    map_put(options, "secret", Value(BASIC_PASS));
    auto client = liveClient(options, [&](const Value& headers) {
      roundSent.fetch_add(1);
      if (carries(headers, pair)) roundPaired.fetch_add(1);
    });
    auto utility = client->getUtility();
    auto root = client->getRootCtx();
    std::string r = "basic-" + std::to_string(round);
    std::atomic<int> registering{1};
    std::mutex mu;
    std::vector<std::string> failed;
    auto thrown = atOnce([&](int n) {
      if (0 == n) {
        registerSecrets(utility, root, r, n, registering);
        return;
      }
      // Bounded, as requests that never pause can hold off a registration.
      int made = 0;
      do {
        Value got = client->direct(vmap({{"path", Value("p" + std::to_string(n))}}));
        if (!is_true(getp(got, "ok"))) {
          std::lock_guard<std::mutex> lk(mu);
          failed.push_back(sdktest::vstr(got));
          return;
        }
      } while (0 < registering.load() && ++made < OPS);
    });
    if (!thrown.empty()) {
      ASSERT_TRUE(false, "round " + r + " threw: " + thrown[0]);
      return;
    }
    if (!failed.empty()) {
      ASSERT_TRUE(false, "round " + r + ", a request failed: " + failed[0]);
      return;
    }
    int rsent = roundSent.load();
    int rpaired = roundPaired.load();
    if (0 < rpaired && rpaired != rsent) {
      ASSERT_TRUE(false, "round " + r + ": " + std::to_string(rpaired) + " of " +
                  std::to_string(rsent) + " requests carried the Basic pair");
      return;
    }
    std::vector<std::string> known{BASIC_USER, BASIC_PASS};
    if (0 < rpaired) known.push_back(pair);
    std::string raw = unmaskedSecret(utility, root, r, 1, known);
    if (!raw.empty()) {
      ASSERT_TRUE(false, "round " + r + ": " + raw + " was registered but not masked");
      return;
    }
    sent += rsent;
    paired += rpaired;
  }
  std::cout << "concurrency_test: " << paired << " of " << sent
            << " requests carried the Basic pair\n";
  ASSERT_TRUE(true, "every request succeeded while the Basic pair and secrets registered");
}

int main() {
  T_RUN(concurrent_first_requests_succeed);
  T_RUN(concurrent_resolutions_share_one_cached_operation);
  T_RUN(concurrent_registration_keeps_every_secret_masked);
  T_RUN(concurrent_requests_survive_registration);
  T_RUN(concurrent_basic_requests_survive_registration);
  return sdktest::summary("concurrency_test");
}

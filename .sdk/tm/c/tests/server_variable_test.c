// A templated base URL takes each {name} from the `server` option. A missing
// or empty value stops construction; test mode fills in test-<name>.

#include "ctest.h"

#include <stdlib.h>

#ifndef _WIN32
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

// A variable no API declares, so the API's own server defaults cannot fill it.
#define BASE "https://api.example.test/bot{zzvar}"

static const char* base_of(UnivecSDK* sdk) {
  return get_str(sdk_options_map(sdk), "base");
}

#ifndef _WIN32
// Construction stops the process, so it runs in a child: what it printed is
// read back, and the status says whether construction returned.
static const char* construct_in_child(voxgig_value* server, int* status) {
  static char buf[4096];
  int fds[2];
  if (0 != pipe(fds)) return NULL;
  fflush(NULL);
  pid_t pid = fork();
  if (0 == pid) {
    struct rlimit nocore = {0, 0};
    setrlimit(RLIMIT_CORE, &nocore);
    dup2(fds[1], 2);
    close(fds[0]);
    projectname_sdk_new(cmap(2, "base", v_str(BASE), "server", server));
    _exit(0);
  }
  close(fds[1]);
  size_t len = 0;
  ssize_t n;
  while (0 < (n = read(fds[0], buf + len, sizeof(buf) - 1 - len))) len += (size_t)n;
  buf[len] = '\0';
  close(fds[0]);
  waitpid(pid, status, 0);
  return buf;
}
#endif

int main(void) {
#ifndef _WIN32
  voxgig_value* servers[2] = { v_map(), cmap(1, "zzvar", v_str("")) };
  for (int i = 0; i < 2; i++) {
    int status = 0;
    const char* err = construct_in_child(servers[i], &status);
    CHECK(NULL != err, "the construction could be run in a child process");
    CHECK(!(WIFEXITED(status) && 0 == WEXITSTATUS(status)),
          "construction stops without a value for zzvar");
    CHECK(err && strstr(err, "the server variable 'zzvar' is required"),
          "the error names the variable");
    CHECK(err && strstr(err, BASE), "the error quotes the base URL");
  }
#else
  printf("server_variable_test: no fork() here, so the stopped construction is not run\n");
#endif

  UnivecSDK* filled = projectname_sdk_new(cmap(2,
    "base", v_str(BASE), "server", cmap(1, "zzvar", v_str("T1"))));
  CHECK_STR_EQ(base_of(filled), "https://api.example.test/botT1", "a server value fills the base");

  UnivecSDK* testmode = projectname_sdk_new(cmap(2,
    "base", v_str(BASE), "test", cmap(1, "active", v_bool(true))));
  CHECK_STR_EQ(base_of(testmode), "https://api.example.test/bottest-zzvar",
               "the test option fills test-<name>");

  UnivecSDK* mock = test_sdk(NULL, cmap(1, "base", v_str(BASE)));
  CHECK_STR_EQ(base_of(mock), "https://api.example.test/bottest-zzvar",
               "the test feature fills test-<name>");

  TEST_SUMMARY("server_variable_test");
}

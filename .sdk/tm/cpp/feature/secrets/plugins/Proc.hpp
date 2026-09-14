// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/plugins/Proc.hpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Running another program, and the environment it inherits.
//
// Two of the ten kinds read a secret out of a CLI - boru and secretspec -
// and a child process is exactly the sort of thing the split exists to
// keep out of the core: `fork` and `execve` are one `#include` away in any
// C++ file, and a chain of built-ins must link neither.
//
// The argument list is passed as an array, never through a shell, and no
// secret is ever put on a command line where the process table publishes
// it.

#ifndef SEKRETO_PLUGINS_PROC_HPP
#define SEKRETO_PLUGINS_PROC_HPP

#include <string>
#include <vector>

#include "../sekreto/Providers.hpp"
#include "../sekreto/Sekreto.hpp"

namespace sekreto {

/// What a finished child process left behind.
struct Ran {
  std::string out;
  std::string why;
  int status = 0;
};

/// Run a child to completion and collect both its streams. Raises a
/// SekretoError when the program cannot be run at all.
Ran runcmd(const std::vector<std::string>& argv,
           const std::vector<std::string>& environment, const std::string& command);

/// The process environment as `KEY=value` entries.
std::vector<std::string> processenv();

/// Set one variable in such a list, in place where it is already there.
void setenvvar(std::vector<std::string>& environment, const std::string& key,
               const std::string& value);

}  // namespace sekreto

#endif

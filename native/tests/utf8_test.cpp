#include <cstdio>
#include <cstdlib>
#include <string>
#include "utf8_util.h"
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); std::exit(1);} } while (0)
static std::string run(std::string in, bool fin, std::string *carry = nullptr) {
  std::string out; lai::utf8_sanitize(in, fin, out); if (carry) *carry = in; return out;
}
int main() {
  const std::string R = "\xEF\xBF\xBD";
  std::string c;
  CHECK(run("", false) == "");
  CHECK(run("abc", false) == "abc");
  CHECK(run("\xD9\x85", false) == "\xD9\x85");
  // incomplete tail: carried when not final, dropped when final
  CHECK(run("a\xD9", false, &c) == "a" && c == "\xD9");
  CHECK(run("a\xD9", true, &c) == "a" && c.empty());
  CHECK(run("\xE2\x82", false, &c) == "" && c == "\xE2\x82");
  CHECK(run("\xE2\x82", true) == "");
  CHECK(run("x\xF0\x9F\x98", true) == "x");
  CHECK(run("\xF0\x9F\x98\x80", true) == "\xF0\x9F\x98\x80");
  // malformed -> U+FFFD (maximal subpart)
  CHECK(run("\x80", true) == R);                       // stray continuation
  CHECK(run("\xC0\xAF", true) == R + R);               // overlong
  CHECK(run("\xE2" "D", true) == R + "D");             // lead + non-continuation
  CHECK(run("\xED\xA0\x80", true) == R + R + R);       // UTF-16 surrogate
  CHECK(run("\xF4\x90\x80\x80", true) == R + R + R + R); // > U+10FFFF
  CHECK(run("\xF5", true) == R);
  CHECK(run("\xFF", true) == R);
  // carry then completion across two calls
  { std::string buf = "\xD9"; std::string out; lai::utf8_sanitize(buf, false, out);
    CHECK(out.empty() && buf == "\xD9"); buf += "\x85"; lai::utf8_sanitize(buf, false, out);
    CHECK(out == "\xD9\x85" && buf.empty()); }
  std::puts("utf8_test OK");
}

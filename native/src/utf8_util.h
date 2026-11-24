// Pure helper (no llama dependency) so it can be unit-tested on the host.
// Strict UTF-8 (Unicode Table 3-7): no overlongs, no surrogates, max U+10FFFF.
#pragma once
#include <cstddef>
#include <string>

namespace lai {

inline bool utf8_lead(unsigned char c, int &len, unsigned char &lo, unsigned char &hi) {
  lo = 0x80; hi = 0xBF;
  if (c < 0x80) { len = 1; return true; }
  if (c >= 0xC2 && c <= 0xDF) { len = 2; return true; }
  if (c == 0xE0) { len = 3; lo = 0xA0; return true; }
  if (c == 0xED) { len = 3; hi = 0x9F; return true; }
  if (c >= 0xE1 && c <= 0xEF) { len = 3; return true; }
  if (c == 0xF0) { len = 4; lo = 0x90; return true; }
  if (c >= 0xF1 && c <= 0xF3) { len = 4; return true; }
  if (c == 0xF4) { len = 4; hi = 0x8F; return true; }
  return false;  // 80..C1, F5..FF
}

// Consumes `buf` (carry from previous call + new bytes). Appends ONLY valid UTF-8
// to `out`; each maximal invalid subpart becomes one U+FFFD. A valid-so-far
// incomplete sequence at the end is left in `buf` as carry when !final_chunk, and
// DROPPED when final_chunk (a truncated character is never passed on).
inline void utf8_sanitize(std::string &buf, bool final_chunk, std::string &out) {
  const size_t n = buf.size();
  size_t i = 0;
  while (i < n) {
    unsigned char c = (unsigned char)buf[i];
    int len; unsigned char lo, hi;
    if (!utf8_lead(c, len, lo, hi)) { out += "\xEF\xBF\xBD"; ++i; continue; }
    if (len == 1) { out += (char)c; ++i; continue; }
    int j = 1;
    bool bad = false;
    while (j < len) {
      if (i + (size_t)j >= n) break;  // ran out of input
      unsigned char d = (unsigned char)buf[i + (size_t)j];
      unsigned char l = j == 1 ? lo : 0x80, h = j == 1 ? hi : 0xBF;
      if (d < l || d > h) { bad = true; break; }
      ++j;
    }
    if (bad) { out += "\xEF\xBF\xBD"; i += (size_t)j; continue; }
    if (j < len) {  // incomplete but valid so far
      if (final_chunk) { buf.clear(); return; }
      buf.erase(0, i);
      return;
    }
    out.append(buf, i, (size_t)len);
    i += (size_t)len;
  }
  buf.clear();
}

}  // namespace lai

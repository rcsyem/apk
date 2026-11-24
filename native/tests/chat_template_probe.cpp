// Ground truth for the preliminary chat-template check: asks the REAL libllama whether it can apply a
// template string. Usage: chat_template_probe <file>...   (each file = one raw template; read as a C string,
// exactly how lai_bridge passes llama_model_chat_template()). Prints "<file>\t<rc>" (rc >= 0 => supported).
#include "llama.h"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <vector>
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    std::ifstream f(argv[i], std::ios::binary);
    std::stringstream ss; ss << f.rdbuf();
    std::string t = ss.str();
    llama_chat_message m[2] = {{"system", "s"}, {"user", "u"}};
    std::vector<char> buf(1 << 16);
    int rc = llama_chat_apply_template(t.c_str(), m, 2, true, buf.data(), (int32_t)buf.size());
    printf("%s\t%d\n", argv[i], rc);
  }
  return 0;
}

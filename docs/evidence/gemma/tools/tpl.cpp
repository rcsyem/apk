#include "llama.h"
#include <cstdio>
#include <vector>
#include <string>
int main(int,char**argv){
  llama_backend_init(); auto mp=llama_model_default_params(); mp.n_gpu_layers=0;
  llama_model*m=llama_model_load_from_file(argv[1],mp); const llama_vocab*v=llama_model_get_vocab(m);
  const char*t=llama_model_chat_template(m,nullptr);
  llama_chat_message msg{"user","What is the capital of France? Answer in one sentence."};
  std::vector<char> b(4096); int n=llama_chat_apply_template(t,&msg,1,true,b.data(),b.size());
  std::string p(b.data(),n); printf("rendered(%d): [",n); for(char c:p) { if(c=='\n') printf("\\n"); else putchar(c);} puts("]");
  std::vector<llama_token> tk(256); int k=llama_tokenize(v,p.c_str(),p.size(),tk.data(),tk.size(),true,true);
  printf("n_tokens=%d:",k); for(int i=0;i<k;i++) printf(" %d",tk[i]); puts("");
  llama_model_free(m); }

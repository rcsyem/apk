// logit dump: greedy path, prints top-3 logits per step and the margin. mode "bridge": explicit pos + chunked batch + n_ctx arg (like lai_bridge); mode "simple": llama_batch_get_one
#include "llama.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <algorithm>
int main(int argc,char**argv){
  const char*path=argv[1]; bool bridge=!strcmp(argv[2],"bridge"); int nctx=atoi(argv[3]); int steps=atoi(argv[4]);
  llama_log_set([](ggml_log_level,const char*,void*){},nullptr);
  llama_backend_init(); auto mp=llama_model_default_params(); mp.n_gpu_layers=0; if(bridge) mp.load_mode=LLAMA_LOAD_MODE_MMAP;
  llama_model*m=llama_model_load_from_file(path,mp); const llama_vocab*v=llama_model_get_vocab(m);
  auto cp=llama_context_default_params(); cp.n_ctx=nctx; cp.n_batch=bridge?512:nctx; cp.n_ubatch=cp.n_batch; cp.n_threads=2; cp.n_threads_batch=2;
  llama_context*c=llama_init_from_model(m,cp);
  const char*p="<start_of_turn>user\nWhat is the capital of France? Answer in one sentence.<end_of_turn>\n<start_of_turn>model\n";
  std::vector<llama_token> t(256); int n=llama_tokenize(v,p,strlen(p),t.data(),256,true,true); t.resize(n);
  llama_batch b=llama_batch_init(512,0,1); int past=0;
  auto run=[&](llama_token*tk,int k){ if(bridge){ b.n_tokens=k; for(int i=0;i<k;i++){b.token[i]=tk[i];b.pos[i]=past+i;b.n_seq_id[i]=1;b.seq_id[i][0]=0;b.logits[i]=(i==k-1);} llama_decode(c,b);} else { llama_decode(c,llama_batch_get_one(tk,k)); } past+=k; };
  run(t.data(),n);
  for(int s=0;s<steps;s++){
    const float*lg=llama_get_logits_ith(c,-1); int nv=llama_vocab_n_tokens(v);
    std::vector<int> id(nv); for(int i=0;i<nv;i++)id[i]=i; std::partial_sort(id.begin(),id.begin()+3,id.end(),[&](int a,int d){return lg[a]>lg[d];});
    char pb[64]; llama_token_to_piece(v,id[0],pb,63,0,true); pb[ (int)strlen(pb)]=0;
    printf("%2d top1=%6d %-14.14s %.5f | top2=%6d %.5f | top3=%6d %.5f | margin12=%.5f\n",s,id[0],pb,lg[id[0]],id[1],lg[id[1]],id[2],lg[id[2]],lg[id[0]]-lg[id[1]]);
    llama_token nx=id[0]; run(&nx,1);
  }
  return 0; }

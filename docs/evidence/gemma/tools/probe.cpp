#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "lai_bridge.h"
using C=std::chrono::steady_clock;
static void go(lai_engine*e,std::vector<const char*> roles,std::vector<const char*> msgs,int maxn){
  char err[256]={0}; auto t0=C::now();
  int rc=lai_generate_start(e,roles.data(),msgs.data(),(int)roles.size(),0.0f,maxn,err,sizeof err);
  if(rc){printf("start rc=%d %s\n",rc,err);return;}
  std::string out; char b[512]; int n=0,pieces=0; double first=-1;
  for(;;){int st=lai_next(e,b,sizeof b,100,&n); if(st==LAI_NEXT_PIECE){ if(first<0)first=std::chrono::duration<double,std::milli>(C::now()-t0).count(); out.append(b,n);pieces++;} else if(st==LAI_NEXT_DONE)break;}
  double tot=std::chrono::duration<double,std::milli>(C::now()-t0).count();
  int pt=0,gt=0; lai_stats(e,&pt,&gt); int stp=0; int r=lai_result(e,&stp,err,sizeof err);
  printf("rc=%d prompt_tok=%d gen_tok=%d first=%.0fms total=%.0fms decode_tps=%.1f\n---\n%s\n---\n",r,pt,gt,first,tot,gt>1?(gt-1)*1000.0/(tot-first):0.0,out.c_str());
}
int main(int argc,char**argv){
  char err[256]={0}; lai_engine*e=nullptr; if(lai_load(argv[1],argc>2?atoi(argv[2]):2048,argc>3?atoi(argv[3]):2,&e,err,sizeof err)){puts(err);return 1;}
  puts("## EN"); go(e,{"user"},{"What is the capital of France? Answer in one sentence."},48);
  puts("## mixed AR/EN"); go(e,{"user"},{"ما معنى كلمة 'sun' بالعربية؟ Reply briefly."},48);
  puts("## multi-turn (context carried?)"); go(e,{"user","assistant","user"},{"My name is Karim.","Nice to meet you, Karim.","What is my name?"},32);
  lai_free(e); return 0; }

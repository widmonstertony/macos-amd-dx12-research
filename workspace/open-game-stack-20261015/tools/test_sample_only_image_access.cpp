// Owned CPU-only qualification and private offline SPIR-V census. No GPU calls.
#include "../src/sample_only_image_access.h"
#include <spirv-tools/libspirv.h>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <iterator>
#include <sstream>
using namespace sample_only_image_access;
static uint64_t checks=0,validations=0;
static void need(bool b,const char*m){++checks;if(!b)throw std::runtime_error(m);}
static bool validate(const uint32_t*w,size_t n,void*) noexcept {
 ++validations;spv_context c=spvContextCreate(SPV_ENV_VULKAN_1_3);if(!c)return false;
 spv_const_binary_t b{w,n};spv_diagnostic d=nullptr;auto s=spvValidate(c,&b,&d);spvDiagnosticDestroy(d);spvContextDestroy(c);return s==SPV_SUCCESS;
}
static std::vector<uint32_t> load(const std::string&p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("input unavailable");std::vector<char>b((std::istreambuf_iterator<char>(f)),{});if(b.size()%4||b.size()>16777216)throw std::runtime_error("input word alignment/budget");std::vector<uint32_t>w(b.size()/4);if(!b.empty())memcpy(w.data(),b.data(),b.size());return w;}
static size_t find(const std::vector<uint32_t>&w,unsigned op){for(size_t at=5;at<w.size();at+=w[at]>>16)if((w[at]&65535)==op)return at;throw std::runtime_error("fixture op not found");}
static std::string quote(const std::string&s){std::string o="\"";for(unsigned char c:s){if(c=='"'||c=='\\')o+='\\';if(c<32)o+='?';else o+=c;}return o+'"';}
static void print(const std::string&p,const Result&r){std::cout<<"{\"path\":"<<quote(p)<<",\"eligible\":"<<(r.eligible?"true":"false")<<",\"semanticallyValidated\":"<<(r.semanticallyValidated?"true":"false")<<",\"reason\":"<<quote(reason_name(r.reason))<<",\"instructionOffset\":"<<r.instructionOffset<<",\"opcode\":"<<r.opcode<<",\"imageTypes\":"<<r.imageTypes<<",\"samplingOperations\":"<<r.samplingOperations<<",\"instructions\":"<<r.instructions<<"}\n";}
int main(int argc,char**argv){try{
 if(argc>=3&&std::string(argv[1])=="--classify"){
  for(int i=2;i<argc;++i){auto w=load(argv[i]);auto before=w;auto r=classify(w.data(),w.size(),validate);need(before==w,"classifier modified caller input");print(argv[i],r);}return 0;
 }
 need(argc==3&&std::string(argv[1])=="--self-test","usage: --self-test fixture-dir or --classify file...");std::string dir=argv[2];
 std::vector<std::pair<const char*,bool>>cases={{"safe_sample",true},{"safe_explicit",true},{"safe_gather",true},{"safe_glsl_math",true},{"safe_physical_address",true},{"safe_demote",true},{"unsafe_image_query",false},{"unsafe_fetch",false},{"unsafe_read",false},{"unsafe_write",false},{"unsafe_unused_function",false},{"unsafe_buffer_atomic",false},{"unsafe_unknown_extension",false},{"unsafe_texel_buffer_type",false},{"unsafe_input_attachment_type",false}};
 for(auto item:cases){auto w=load(dir+"/"+item.first+".spv");need(validate(w.data(),w.size(),nullptr),"authored fixture not semantically valid");auto before=w;errno=EDOM;auto r=classify(w.data(),w.size(),validate);need(errno==EDOM,"errno not preserved");need(r.eligible==item.second,"unexpected fixture eligibility");need(!r.eligible||r.semanticallyValidated,"unvalidated positive classification");need(w==before,"input or cached code modified");print(item.first,r);}
 auto base=load(dir+"/safe_sample.spv");need(!classify(base.data(),base.size()).eligible,"missing semantic validator accepted");
 auto rejected=[&](std::vector<uint32_t>w,const char*label){auto before=w;errno=ERANGE;auto r=classify(w.data(),w.size(),validate);need(!r.eligible,label);need(w==before,"malformed input modified");need(errno==ERANGE,"error path errno changed");};
 for(size_t n=0;n<5;++n){auto w=base;w.resize(n);rejected(w,"truncated header accepted");}
 for(auto pair:std::vector<std::pair<size_t,uint32_t>>{{0,0},{1,0},{1,0x00010700},{1,0x10010300},{3,0},{3,1048577},{4,1}}){auto w=base;w[pair.first]=pair.second;rejected(w,"bad header accepted");}
 {auto w=base;w[5]&=65535;rejected(w,"zero word count accepted");}
 {auto w=base;w[5]=(65535u<<16)|(w[5]&65535);rejected(w,"overrun word count accepted");}
 {auto w=base;w.push_back((1u<<16)|65000u);rejected(w,"unknown opcode accepted");}
 {auto w=base;w[6]=0x7fffffffu;rejected(w,"unknown capability accepted");}
 {auto w=base;auto at=find(w,25);w[at+3]=5;rejected(w,"texel buffer type accepted");w=base;at=find(w,25);w[at+7]=2;rejected(w,"storage image type accepted");w=base;at=find(w,25);w[at+6]=1;rejected(w,"MSAA type accepted");}
 {auto w=base;auto at=find(w,62);w[at+1]=w[3]+1;rejected(w,"invalid ID accepted despite semantic validator");}
 {auto w=base;auto at=find(w,87);w[at]=(1u<<16)|87u;rejected(w,"truncated sample instruction accepted");}
 {auto w=load(dir+"/safe_glsl_math.spv");auto at=find(w,12);w[at+4]=999;rejected(w,"unknown GLSL extinst accepted");w=load(dir+"/safe_glsl_math.spv");at=find(w,11);for(unsigned i=2;i<(w[at]>>16);++i)w[at+i]=0x41414141;rejected(w,"unterminated import accepted");}
 for(size_t n=5;n<base.size();++n){auto w=base;w.resize(n);rejected(w,"truncated instruction/function accepted");}
 std::cout<<"{\"selfTestPassed\":true,\"checks\":"<<checks<<",\"semanticValidatorCalls\":"<<validations<<",\"positiveRequiresRealValidator\":true,\"GPUCalls\":0,\"cacheFilesReadOrWritten\":false,\"inputWordsUnchanged\":true}\n";return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 2;}}

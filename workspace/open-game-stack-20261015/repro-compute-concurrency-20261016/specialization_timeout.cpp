// Isolated, deliberate timeout failure test. Never dispatch a failed pipeline.
#define PSO_FIXTURE_NO_MAIN 1
#include "concurrency_gpu.cpp"
#include "mvk_private_api.h"
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
static int crashFD=-1;
static void fault(int sig,siginfo_t* info,void*) {
 const char a[]="{\"passed\":false,\"controlledFailureProbeFault\":true,\"signal\":";
 write(crashFD,a,sizeof(a)-1);char n[20];int i=0;if(sig>=10)n[i++]='0'+sig/10;n[i++]='0'+sig%10;write(crashFD,n,i);const char b[]="}\n";write(crashFD,b,sizeof(b)-1);_exit(86);
}
int main(int argc,char**argv){try {
 if(argc!=4)throw std::runtime_error("specialization_timeout shaders report.json owned_library");
 crashFD=open(argv[2],O_WRONLY|O_CREAT|O_TRUNC,0600);if(crashFD<0)return 3;
 struct sigaction sa{};sa.sa_sigaction=fault;sa.sa_flags=SA_SIGINFO;sigemptyset(&sa.sa_mask);for(int sig:{SIGSEGV,SIGBUS,SIGABRT})sigaction(sig,&sa,nullptr);
 Fixture f(argv[1]);auto cache=f.cache();auto module=f.module("specialize.spv");
 auto create=[&](uint32_t value,VkPipeline* out) {
  VkSpecializationMapEntry entry{0,0,4};VkSpecializationInfo spec{1,&entry,4,&value};VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};ci.layout=f.layout;ci.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};ci.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;ci.stage.module=module;ci.stage.pName="main";ci.stage.pSpecializationInfo=&spec;
  return vkCreateComputePipelines(f.g.device,cache,1,&ci,nullptr,out);
 };
 VkPipeline warm=VK_NULL_HANDLE;CHECK(create(7,&warm));vkDestroyPipeline(f.g.device,warm,nullptr);
 void* owned=dlopen(argv[3],RTLD_NOW|RTLD_LOCAL);if(!owned)throw std::runtime_error("Owned library unavailable");
 using Get=VkResult(*)(VkInstance,MVKConfiguration*,size_t*);using Set=VkResult(*)(VkInstance,const MVKConfiguration*,size_t*);
 auto get=(Get)dlsym(owned,"vkGetMoltenVKConfigurationMVK");auto set=(Set)dlsym(owned,"vkSetMoltenVKConfigurationMVK");if(!get||!set)throw std::runtime_error("Configuration API unavailable");
 MVKConfiguration config{};size_t size=sizeof(config);CHECK(get(VK_NULL_HANDLE,&config,&size));auto original=config;config.metalCompileTimeout=0;size=sizeof(config);CHECK(set(VK_NULL_HANDLE,&config,&size));
 fprintf(stderr,"PHASE specialization-timeout\n");fflush(stderr);VkPipeline timed=VK_NULL_HANDLE;auto start=Clock::now();VkResult result=create(0x12345678u,&timed);double elapsed=ms(start,Clock::now());
 size=sizeof(original);CHECK(set(VK_NULL_HANDLE,&original,&size));fprintf(stderr,"TIMEOUT returned=%d pipeline=%p ms=%.3f; awaiting real callback\n",result,(void*)timed,elapsed);fflush(stderr);
 if(timed)vkDestroyPipeline(f.g.device,timed,nullptr);
 // No fake compiler completion/cancellation. Leave the live device/cache/module
 // available while the real asynchronous Metal completion runs.
 std::this_thread::sleep_for(std::chrono::seconds(2));
 VkPipeline recovery=VK_NULL_HANDLE;VkResult recovered=create(13,&recovery);bool ok=result!=VK_SUCCESS&&timed==VK_NULL_HANDLE&&recovered==VK_SUCCESS&&recovery;
 // Recovery is actually executed, with an independently computed scalar result.
 if(recovery){memset(f.output.p,0xcd,256);VkDescriptorBufferInfo bi[]={{f.input.b,0,2048},{f.output.b,0,256}};VkWriteDescriptorSet w[2]{};for(int i=0;i<2;i++){w[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;w[i].dstSet=f.set;w[i].dstBinding=i;w[i].descriptorCount=1;w[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;w[i].pBufferInfo=&bi[i];}vkUpdateDescriptorSets(f.g.device,2,w,0,nullptr);f.g.run([&](VkCommandBuffer cb){VkMemoryBarrier b{VK_STRUCTURE_TYPE_MEMORY_BARRIER};b.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;b.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&b,0,nullptr,0,nullptr);vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,recovery);vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,f.layout,0,1,&f.set,0,nullptr);vkCmdDispatch(cb,1,1,1);b.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT;b.dstAccessMask=VK_ACCESS_HOST_READ_BIT;vkCmdPipelineBarrier(cb,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&b,0,nullptr,0,nullptr);});for(unsigned i=0;i<64;i++)if(static_cast<uint32_t*>(f.output.p)[i]!=((1000+6*i)^(1003+6*i))+13)f.mismatches++;vkDestroyPipeline(f.g.device,recovery,nullptr);}
 vkDestroyShaderModule(f.g.device,module,nullptr);vkDestroyPipelineCache(f.g.device,cache,nullptr);close(crashFD);crashFD=-1;std::ofstream report(argv[2]);report<<"{\"passed\":"<<(ok&&f.mismatches==0?"true":"false")<<",\"timeoutResult\":"<<result<<",\"timedPipelineNull\":"<<(!timed?"true":"false")<<",\"timeoutMilliseconds\":"<<elapsed<<",\"recoveryResult\":"<<recovered<<",\"gpuWordsChecked\":64,\"mismatches\":"<<f.mismatches<<",\"callbackAllowedToComplete\":true,\"forcedTimeoutOnlyInIsolatedProbe\":true}\n";return ok&&f.mismatches==0?0:1;
 }catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}

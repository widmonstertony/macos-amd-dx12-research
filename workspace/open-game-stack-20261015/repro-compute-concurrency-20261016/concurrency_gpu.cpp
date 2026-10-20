#include "gpu_common.hpp"
#include <atomic>
#include <chrono>
#include <filesystem>
#include <future>
#include <sstream>
#include <thread>

using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point a, Clock::time_point b) {
 return std::chrono::duration<double,std::milli>(b-a).count();
}
struct Result {
 VkPipeline pipeline=VK_NULL_HANDLE; VkResult result=VK_NOT_READY;
 VkPipelineCreationFeedback feedback{},stageFeedback{}; double milliseconds=0;
 unsigned variant=0;
};
struct Fixture {
 GPU g; std::filesystem::path dir; VkDescriptorSetLayout setLayout;
 VkPipelineLayout layout; VkDescriptorPool pool; VkDescriptorSet set;
 Buf input,output; uint64_t checked=0,mismatches=0;
 Fixture(const char* path):dir(path) {
  VkDescriptorSetLayoutBinding b[]={{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr},{1,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,nullptr}};
  VkDescriptorSetLayoutCreateInfo li{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};li.bindingCount=2;li.pBindings=b;CHECK(vkCreateDescriptorSetLayout(g.device,&li,nullptr,&setLayout));
  VkPipelineLayoutCreateInfo pi{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};pi.setLayoutCount=1;pi.pSetLayouts=&setLayout;CHECK(vkCreatePipelineLayout(g.device,&pi,nullptr,&layout));
  VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,2};VkDescriptorPoolCreateInfo ci{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};ci.maxSets=1;ci.poolSizeCount=1;ci.pPoolSizes=&size;CHECK(vkCreateDescriptorPool(g.device,&ci,nullptr,&pool));
  VkDescriptorSetAllocateInfo ai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};ai.descriptorPool=pool;ai.descriptorSetCount=1;ai.pSetLayouts=&setLayout;CHECK(vkAllocateDescriptorSets(g.device,&ai,&set));
  input=g.buffer(2048,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);output=g.buffer(256,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
  for(unsigned i=0;i<512;i++)static_cast<uint32_t*>(input.p)[i]=1000+3*i;
 }
 VkShaderModule module(const std::string& name) {
  std::ifstream in(dir/name,std::ios::binary|std::ios::ate);if(!in)throw std::runtime_error("Missing shader "+name);size_t n=in.tellg();in.seekg(0);std::vector<uint32_t> words(n/4);in.read((char*)words.data(),n);
  VkShaderModuleCreateInfo ci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};ci.codeSize=n;ci.pCode=words.data();VkShaderModule result;CHECK(vkCreateShaderModule(g.device,&ci,nullptr,&result));return result;
 }
 VkPipelineCache cache(const std::vector<char>& data={}) {
  VkPipelineCacheCreateInfo ci{VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};ci.initialDataSize=data.size();ci.pInitialData=data.data();VkPipelineCache c;CHECK(vkCreatePipelineCache(g.device,&ci,nullptr,&c));return c;
 }
 Result create(unsigned variant,VkPipelineCache cache,const char* name="main") {
  // Module data, module, layout and cache stay alive throughout synchronous
  // vkCreateComputePipelines, including every internal asynchronous callback.
  auto m=module("case"+std::to_string(variant)+".spv");Result result;result.variant=variant;
  VkPipelineCreationFeedbackCreateInfo feedback{VK_STRUCTURE_TYPE_PIPELINE_CREATION_FEEDBACK_CREATE_INFO};feedback.pPipelineCreationFeedback=&result.feedback;feedback.pipelineStageCreationFeedbackCount=1;feedback.pPipelineStageCreationFeedbacks=&result.stageFeedback;
  VkComputePipelineCreateInfo ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};ci.pNext=&feedback;ci.layout=layout;ci.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};ci.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;ci.stage.module=m;ci.stage.pName=name;
  auto start=Clock::now();result.result=vkCreateComputePipelines(g.device,cache,1,&ci,nullptr,&result.pipeline);result.milliseconds=ms(start,Clock::now());vkDestroyShaderModule(g.device,m,nullptr);return result;
 }
 void check(Result& result,unsigned range=2048) {
  CHECK(result.result);if(!result.pipeline)throw std::runtime_error("Success without pipeline");
  memset(output.p,0xcd,256);VkDescriptorBufferInfo buffers[]={{input.b,0,range},{output.b,0,256}};VkWriteDescriptorSet writes[2]{};
  for(unsigned i=0;i<2;i++){writes[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;writes[i].dstSet=set;writes[i].dstBinding=i;writes[i].descriptorCount=1;writes[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;writes[i].pBufferInfo=&buffers[i];}vkUpdateDescriptorSets(g.device,2,writes,0,nullptr);
  g.run([&](VkCommandBuffer cmd){VkMemoryBarrier b{VK_STRUCTURE_TYPE_MEMORY_BARRIER};b.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;b.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&b,0,nullptr,0,nullptr);vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,result.pipeline);vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,layout,0,1,&set,0,nullptr);vkCmdDispatch(cmd,1,1,1);b.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT;b.dstAccessMask=VK_ACCESS_HOST_READ_BIT;vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&b,0,nullptr,0,nullptr);});
  for(unsigned t=0;t<64;t++) {uint32_t h=0x9e3779b9u^result.variant;for(unsigned k=0;k<64;k++){unsigned index=(t+17*k)&255u;uint32_t x=index*8+4<=range?1000+3*(index*2):0,y=index*8+8<=range?1000+3*(index*2+1):0;h=(h^x)*1664525u+y+1013904223u;h=(h<<7)|(h>>25);}checked++;if(static_cast<uint32_t*>(output.p)[t]!=h)mismatches++;}
  for(unsigned i=0;i<512;i++){checked++;if(static_cast<uint32_t*>(input.p)[i]!=1000+3*i)mismatches++;}
 }
 ~Fixture(){g.destroy(input);g.destroy(output);vkDestroyDescriptorPool(g.device,pool,nullptr);vkDestroyPipelineLayout(g.device,layout,nullptr);vkDestroyDescriptorSetLayout(g.device,setLayout,nullptr);}
};
#ifndef PSO_FIXTURE_NO_MAIN
int main(int argc,char** argv) {try {
 if(argc!=3)throw std::runtime_error("concurrency_gpu shaderDir output.json");Fixture f(argv[1]);std::ostringstream phases;bool comma=false;unsigned failed=0;
 for(unsigned phase=0;phase<3;phase++) {
  const unsigned workers=phase==0?1:2;const bool shared=phase!=2;std::vector<VkPipelineCache> caches(shared?1:workers);for(auto&c:caches)c=f.cache();
  for(unsigned warm=0;warm<2;warm++) {
   std::vector<Result> results(4);std::atomic<unsigned> next{0},active{0},peak{0};std::vector<std::thread> threads;auto start=Clock::now();
   for(unsigned w=0;w<workers;w++)threads.emplace_back([&,w]{for(unsigned i=w;i<4;i+=workers){unsigned a=active.fetch_add(1)+1;unsigned p=peak.load();while(p<a&&!peak.compare_exchange_weak(p,a)){};results[i]=f.create(phase*4+i,caches[shared?0:w]);active.fetch_sub(1);}});
   for(auto&t:threads)t.join();double elapsed=ms(start,Clock::now()),sum=0;unsigned hits=0;
   if(comma)phases<<",";comma=true;phases<<"{\"phase\":"<<phase<<",\"workers\":"<<workers<<",\"sharedCache\":"<<(shared?"true":"false")<<",\"warm\":"<<(warm?"true":"false")<<",\"wallMilliseconds\":"<<elapsed<<",\"peakRequests\":"<<peak.load()<<",\"jobs\":[";
   for(unsigned i=0;i<4;i++){auto&r=results[i];sum+=r.milliseconds;bool valid=r.feedback.flags&VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT;bool hit=valid&&(r.stageFeedback.flags&VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT)&&(r.stageFeedback.flags&VK_PIPELINE_CREATION_FEEDBACK_APPLICATION_PIPELINE_CACHE_HIT_BIT);hits+=hit;if(i)phases<<",";phases<<"{\"variant\":"<<r.variant<<",\"result\":"<<r.result<<",\"milliseconds\":"<<r.milliseconds<<",\"cacheHit\":"<<(hit?"true":"false")<<"}";if(r.result==VK_SUCCESS){f.check(r);f.check(r,13);}else failed++;if(r.pipeline)vkDestroyPipeline(f.g.device,r.pipeline,nullptr);}
   phases<<"],\"sumRequestMilliseconds\":"<<sum<<",\"cacheHits\":"<<hits<<"}";std::cout<<"PHASE "<<phase<<" warm="<<warm<<" ms="<<elapsed<<" hits="<<hits<<" mismatches="<<f.mismatches<<std::endl;
  }
  // Serialize only after joins. Destroy original cache before using a PSO
  // from a deserialized cache; pipeline state must own what it needs itself.
  size_t n=0;CHECK(vkGetPipelineCacheData(f.g.device,caches[0],&n,nullptr));std::vector<char> bytes(n);CHECK(vkGetPipelineCacheData(f.g.device,caches[0],&n,bytes.data()));bytes.resize(n);
  auto copy=f.cache(bytes);auto retained=f.create(phase*4,copy);vkDestroyPipelineCache(f.g.device,copy,nullptr);for(auto c:caches)vkDestroyPipelineCache(f.g.device,c,nullptr);f.check(retained);vkDestroyPipeline(f.g.device,retained.pipeline,nullptr);
 }
 // The Vulkan synchronous create call has no cancellation primitive. A job
 // cancelled in flight retains all owners, waits for return, then discards.
 auto cancelCache=f.cache();std::atomic<bool> entered{false},cancel{false};Result cancelled;unsigned discarded=0;
 std::thread inFlight([&]{entered.store(true);cancelled=f.create(0,cancelCache);if(cancel.load()&&cancelled.pipeline){vkDestroyPipeline(f.g.device,cancelled.pipeline,nullptr);cancelled.pipeline=VK_NULL_HANDLE;discarded++;}});
 while(!entered.load())std::this_thread::yield();cancel.store(true);inFlight.join();if(cancelled.result!=VK_SUCCESS||discarded!=1)failed++;
 auto recovered=f.create(0,cancelCache);f.check(recovered);vkDestroyPipeline(f.g.device,recovered.pipeline,nullptr);vkDestroyPipelineCache(f.g.device,cancelCache,nullptr);
 bool pass=failed==0&&f.mismatches==0;std::ofstream out(argv[2]);out<<"{\"passed\":"<<(pass?"true":"false")<<",\"phases\":["<<phases.str()<<"],\"gpuWordsChecked\":"<<f.checked<<",\"mismatches\":"<<f.mismatches<<",\"failures\":"<<failed<<",\"inFlightDiscardedAfterJoin\":"<<discarded<<",\"scope\":\"Owned vector-read stress; not actual game workload or UE lifetime reproduction\"}\n";return pass?0:1;
 }catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 2;}}

#endif

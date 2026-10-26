/* Optional numeric flight recorder. Producers never perform file I/O or wait
 * for the recorder lock. Not part of the rendering/synchronization contract. */
#ifndef VKD3D_FORENSICS_H
#define VKD3D_FORENSICS_H
#ifndef VKF_SYNTHETIC_CPU_CONTROL
#define VKF_SYNTHETIC_CPU_CONTROL 0
#endif
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>

enum vkf_kind { VKF_EXECUTE=1,VKF_WORKER=2,VKF_ENQUEUE=3,VKF_ACQUIRE=4,
    VKF_SUBMIT=5,VKF_WAIT_EDGE=6,VKF_SIGNAL_EDGE=7,VKF_COMMAND_BUFFER=8,
    VKF_PSO_GRAPHICS=9,VKF_PSO_COMPUTE=10,VKF_PSO_STREAM=11,
    VKF_CREATE_GRAPHICS=12,VKF_CREATE_COMPUTE=13,VKF_PIPELINE=14,
    VKF_COND_WAIT=15,VKF_QUEUE_ACQUIRE=16,VKF_SERIAL_DRAIN=17,
    VKF_SEMAPHORE_WAIT=18,VKF_QUEUE_MAP=19,VKF_PSO_BUILD=20,
    VKF_COMMITTED_RESOURCE=21,VKF_PLACED_RESOURCE=22,VKF_RESERVED_RESOURCE=23,
    VKF_HEAP_MEMORY=24,VKF_ALLOCATE_MEMORY=25,VKF_MEMORY_HANDLE=26,
    VKF_MAP_MEMORY=27,VKF_RESOURCE_MAP=28,VKF_RESOURCE_UNMAP=29,
    VKF_FLUSH=30,VKF_INVALIDATE=31 };
struct vkf_errors { int err; uint32_t last; };
struct vkf_event { uint64_t session,qpc,id,parent,a[8]; uint32_t kind,phase,tid; };
struct vkf_scope { uint64_t id,parent,session,start,object,a,b; int64_t result;
    uint32_t kind,has_result; uint64_t end; const void *output; };
struct vkf_copy_scope { void *shard; uint64_t start; };
struct vkf_context { uint64_t scope,work_queue,work_key,vk_queue;
    uint32_t family,index; };
extern _Thread_local struct vkf_context vkf_context;
uint64_t vkf_session(void);
uint64_t vkf_peek_session(void);
uint64_t vkf_qpc(void);
uint64_t vkf_next_id(void);
struct vkf_errors vkf_save_errors(void);
void vkf_restore_errors(struct vkf_errors);
void vkf_emit(uint32_t kind,uint32_t phase,uint64_t session,uint64_t id,uint64_t parent,
        uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t f,uint64_t g,uint64_t h);
struct vkf_copy_scope vkf_copy_begin(uint64_t descriptors,uint32_t heap_type,uint32_t variant);
void vkf_copy_end(struct vkf_copy_scope *scope);
void vkf_queue_mapping(uint64_t queue,uint32_t family,uint32_t index);
void vkf_lookup_queue(uint64_t queue,uint32_t *family,uint32_t *index);

static inline struct vkf_scope vkf_begin(uint32_t kind,uint64_t object,uint64_t a,uint64_t b)
{
    struct vkf_errors errors=vkf_save_errors();
    struct vkf_scope s={0};
    s.session=vkf_session();s.kind=kind;s.object=object;s.a=a;s.b=b;
    if(s.session) {
        s.id=vkf_next_id();s.parent=vkf_context.scope;
        vkf_emit(kind,0,s.session,s.id,s.parent,object,a,b,
                vkf_context.work_queue,vkf_context.work_key,0,0,0);
        vkf_context.scope=s.id;s.start=vkf_qpc();
    }
    vkf_restore_errors(errors);return s;
}
static inline void vkf_end(struct vkf_scope *s)
{
    struct vkf_errors errors=vkf_save_errors();
    if(s->id) {
        uint64_t end=s->end?s->end:vkf_qpc();
        uint64_t output=s->b;
        if(s->output&&s->has_result&&s->result==0){uintptr_t bits=0;memcpy(&bits,s->output,sizeof(bits));output=bits;}
        vkf_context.scope=s->parent;
        vkf_emit(s->kind,1,s->session,s->id,s->parent,s->object,s->a,output,
                end-s->start,(uint64_t)s->result,s->has_result,vkf_peek_session()!=s->session,s->start);
    }
    vkf_restore_errors(errors);
}
static inline int64_t vkf_result(struct vkf_scope *s,int64_t value)
{ s->has_result=1;s->result=value;return value; }
#define VKF_SCOPE(name,kind,object,a,b) struct vkf_scope name __attribute__((cleanup(vkf_end))) = vkf_begin(kind,(uint64_t)(uintptr_t)(object),(uint64_t)(a),(uint64_t)(b))
#define VKF_COPY_SCOPE(descriptors,heap,variant) struct vkf_copy_scope vkf_copy __attribute__((cleanup(vkf_copy_end))) = vkf_copy_begin(descriptors,heap,variant)

static inline void vkf_note(uint32_t kind,uint64_t object,uint64_t a,uint64_t b,uint64_t c)
{
    uint64_t sid=vkf_peek_session();
    if(sid)vkf_emit(kind,2,sid,vkf_next_id(),vkf_context.scope,object,a,b,c,0,0,0,0);
}
static inline void vkf_note_queue(uint32_t kind,uint64_t object,uint64_t type,uint64_t key,
        uint64_t pending,uint64_t vk_queue,uint32_t family,uint32_t index)
{
    uint64_t sid=vkf_peek_session();
    if(sid)vkf_emit(kind,2,sid,vkf_next_id(),vkf_context.scope,object,type,key,pending,vk_queue,family,index,0);
}
struct vkf_work_context {uint64_t queue,key;};
static inline struct vkf_work_context vkf_work_begin(uint64_t queue,uint64_t key)
{
    struct vkf_work_context old={vkf_context.work_queue,vkf_context.work_key};
    vkf_context.work_queue=queue;vkf_context.work_key=key;return old;
}
static inline void vkf_work_end(struct vkf_work_context *old)
{vkf_context.work_queue=old->queue;vkf_context.work_key=old->key;}
#define VKF_WORK_CONTEXT(name,queue,key) struct vkf_work_context name __attribute__((cleanup(vkf_work_end))) = vkf_work_begin((uintptr_t)(queue),(key))
static inline uint64_t vkf_copy_range_count(uint32_t n,const unsigned int *sizes)
{
    uint64_t total=0;uint32_t i;
    if(!vkf_peek_session())return 0;
    for(i=0;i<n;++i)total+=sizes?sizes[i]:1;return total;
}
struct vkf_sampled_api {struct vkf_copy_scope counter;struct vkf_scope span;uint64_t object,argument,session;uint32_t kind;};
static inline struct vkf_sampled_api vkf_sampled_begin(uint32_t kind,uint64_t object,uint64_t argument,uint32_t op,uint64_t units)
{
    struct vkf_errors errors=vkf_save_errors();struct vkf_sampled_api s={0};
    s.kind=kind;s.object=object;s.argument=argument;s.session=vkf_peek_session();
    s.counter=vkf_copy_begin(units,0,256+op);
    if(s.counter.start)s.span=vkf_begin(kind,object,argument,0);
    vkf_restore_errors(errors);return s;
}
static inline int64_t vkf_sampled_result(struct vkf_sampled_api *s,int64_t result)
{
    vkf_result(&s->span,result);
    if(result<0&&!s->span.id&&s->session)vkf_emit(s->kind,2,s->session,vkf_next_id(),vkf_context.scope,
            s->object,(uint64_t)result,s->argument,1,vkf_peek_session()!=s->session,0,0,0);
    return result;
}
static inline void vkf_sampled_end(struct vkf_sampled_api *s)
{
    struct vkf_errors errors=vkf_save_errors();vkf_end(&s->span);vkf_copy_end(&s->counter);vkf_restore_errors(errors);
}
#define VKF_SAMPLED_SCOPE(name,kind,object,argument,op,units) struct vkf_sampled_api name __attribute__((cleanup(vkf_sampled_end))) = vkf_sampled_begin(kind,(uintptr_t)(object),argument,op,units)
#ifndef VKF_PROTOCOL_TEST
static inline VkResult vkf_submit2(PFN_vkQueueSubmit2 fn,VkQueue queue,uint32_t count,
        const VkSubmitInfo2 *infos,VkFence fence)
{
    struct vkf_errors errors;
    VKF_SCOPE(scope,VKF_SUBMIT,queue,count,0);
    VkResult result;
    if(scope.id) {
        uint32_t family=UINT32_MAX,index=UINT32_MAX,i,j,recorded=0,total=0;
        vkf_lookup_queue((uint64_t)(uintptr_t)queue,&family,&index);
        for(i=0;i<count;++i)total+=infos[i].waitSemaphoreInfoCount+infos[i].signalSemaphoreInfoCount+infos[i].commandBufferInfoCount;
        vkf_emit(VKF_SUBMIT,2,scope.session,scope.id,scope.parent,(uint64_t)(uintptr_t)queue,
                family,index,count,total,total>256?total-256:0,vkf_context.work_key,0);
        for(i=0;i<count&&recorded<256;++i) {
            for(j=0;j<infos[i].waitSemaphoreInfoCount&&recorded<256;++j,++recorded) {
                const VkSemaphoreSubmitInfo *v=&infos[i].pWaitSemaphoreInfos[j];
                vkf_emit(VKF_WAIT_EDGE,2,scope.session,scope.id,scope.parent,
                        (uint64_t)(uintptr_t)queue,(uint64_t)(uintptr_t)v->semaphore,v->value,
                        v->stageMask,i,j,v->deviceIndex,0);
            }
            for(j=0;j<infos[i].signalSemaphoreInfoCount&&recorded<256;++j,++recorded) {
                const VkSemaphoreSubmitInfo *v=&infos[i].pSignalSemaphoreInfos[j];
                vkf_emit(VKF_SIGNAL_EDGE,2,scope.session,scope.id,scope.parent,
                        (uint64_t)(uintptr_t)queue,(uint64_t)(uintptr_t)v->semaphore,v->value,
                        v->stageMask,i,j,v->deviceIndex,0);
            }
            for(j=0;j<infos[i].commandBufferInfoCount&&recorded<256;++j,++recorded)
                vkf_emit(VKF_COMMAND_BUFFER,2,scope.session,scope.id,scope.parent,
                        (uint64_t)(uintptr_t)queue,(uint64_t)(uintptr_t)infos[i].pCommandBufferInfos[j].commandBuffer,
                        i,j,infos[i].pCommandBufferInfos[j].deviceMask,0,0,0);
        }
    }
    errors=vkf_save_errors();if(scope.id)scope.start=vkf_qpc();vkf_restore_errors(errors);
    result=fn(queue,count,infos,fence);errors=vkf_save_errors();if(scope.id)scope.end=vkf_qpc();
    vkf_result(&scope,result);vkf_end(&scope);scope.id=0;
    vkf_restore_errors(errors);return result;
}
static inline VkResult vkf_create_graphics(PFN_vkCreateGraphicsPipelines fn,VkDevice device,
        VkPipelineCache cache,uint32_t count,const VkGraphicsPipelineCreateInfo *infos,
        const VkAllocationCallbacks *alloc,VkPipeline *out)
{
    struct vkf_errors errors;uint32_t i;
    VKF_SCOPE(scope,VKF_CREATE_GRAPHICS,device,count,(uintptr_t)cache);
    VkResult result;
    errors=vkf_save_errors();if(scope.id)scope.start=vkf_qpc();vkf_restore_errors(errors);
    result=fn(device,cache,count,infos,alloc,out);errors=vkf_save_errors();if(scope.id)scope.end=vkf_qpc();
    if(scope.id)for(i=0;i<count&&i<64;++i)vkf_emit(VKF_PIPELINE,2,scope.session,scope.id,scope.parent,
            (uintptr_t)out[i],infos[i].flags,i,count,count>64?count-64:0,(uintptr_t)infos[i].layout,0,0);
    vkf_result(&scope,result);vkf_end(&scope);scope.id=0;vkf_restore_errors(errors);return result;
}
static inline VkResult vkf_create_compute(PFN_vkCreateComputePipelines fn,VkDevice device,
        VkPipelineCache cache,uint32_t count,const VkComputePipelineCreateInfo *infos,
        const VkAllocationCallbacks *alloc,VkPipeline *out)
{
    struct vkf_errors errors;uint32_t i;
    VKF_SCOPE(scope,VKF_CREATE_COMPUTE,device,count,(uintptr_t)cache);
    VkResult result;
    errors=vkf_save_errors();if(scope.id)scope.start=vkf_qpc();vkf_restore_errors(errors);
    result=fn(device,cache,count,infos,alloc,out);errors=vkf_save_errors();if(scope.id)scope.end=vkf_qpc();
    if(scope.id)for(i=0;i<count&&i<64;++i)vkf_emit(VKF_PIPELINE,2,scope.session,scope.id,scope.parent,
            (uintptr_t)out[i],infos[i].flags,i,count,count>64?count-64:0,(uintptr_t)infos[i].layout,
            (uintptr_t)infos[i].stage.module,0);
    vkf_result(&scope,result);vkf_end(&scope);scope.id=0;vkf_restore_errors(errors);return result;
}
static inline VkResult vkf_wait_semaphores(PFN_vkWaitSemaphores fn,VkDevice device,
        const VkSemaphoreWaitInfo *info,uint64_t timeout)
{
    struct vkf_errors errors;uint32_t i;
    VKF_SCOPE(scope,VKF_SEMAPHORE_WAIT,device,info->semaphoreCount,timeout);
    if(scope.id)for(i=0;i<info->semaphoreCount&&i<128;++i)
        vkf_emit(VKF_WAIT_EDGE,2,scope.session,scope.id,scope.parent,0,(uintptr_t)info->pSemaphores[i],
                info->pValues[i],0,0,i,info->semaphoreCount>128?info->semaphoreCount-128:0,0);
    VkResult result;
    errors=vkf_save_errors();if(scope.id)scope.start=vkf_qpc();vkf_restore_errors(errors);
    result=fn(device,info,timeout);errors=vkf_save_errors();if(scope.id)scope.end=vkf_qpc();
    vkf_result(&scope,result);vkf_end(&scope);scope.id=0;vkf_restore_errors(errors);return result;
}
static inline VkResult vkf_allocate_memory(PFN_vkAllocateMemory fn,VkDevice device,const VkMemoryAllocateInfo *info,const VkAllocationCallbacks *alloc,VkDeviceMemory *out)
{
    struct vkf_errors errors;VkResult result;
    VKF_SCOPE(scope,VKF_ALLOCATE_MEMORY,device,info->allocationSize,info->memoryTypeIndex);
    errors=vkf_save_errors();if(scope.id)scope.start=vkf_qpc();vkf_restore_errors(errors);
    result=fn(device,info,alloc,out);errors=vkf_save_errors();if(scope.id)scope.end=vkf_qpc();
    if(scope.id&&result==VK_SUCCESS)vkf_emit(VKF_MEMORY_HANDLE,2,scope.session,scope.id,scope.parent,(uintptr_t)*out,info->allocationSize,info->memoryTypeIndex,0,0,0,0,0);
    vkf_result(&scope,result);vkf_end(&scope);scope.id=0;vkf_restore_errors(errors);return result;
}
static inline VkResult vkf_map_memory(PFN_vkMapMemory fn,VkDevice device,VkDeviceMemory memory,VkDeviceSize offset,VkDeviceSize size,VkMemoryMapFlags flags,void **out)
{
    struct vkf_errors errors;VkResult result;
    VKF_SCOPE(scope,VKF_MAP_MEMORY,memory,offset,size);
    errors=vkf_save_errors();if(scope.id)scope.start=vkf_qpc();vkf_restore_errors(errors);
    result=fn(device,memory,offset,size,flags,out);errors=vkf_save_errors();if(scope.id)scope.end=vkf_qpc();
    vkf_result(&scope,result);vkf_end(&scope);scope.id=0;vkf_restore_errors(errors);return result;
}
static inline VkResult vkf_mapped_ranges(PFN_vkFlushMappedMemoryRanges fn,uint32_t kind,VkDevice device,uint32_t count,const VkMappedMemoryRange *ranges)
{
    struct vkf_errors errors;VkResult result;
    VKF_SAMPLED_SCOPE(scope,kind,device,count,kind==VKF_FLUSH?3:4,count);
    errors=vkf_save_errors();if(scope.span.id)scope.span.start=vkf_qpc();vkf_restore_errors(errors);
    result=fn(device,count,ranges);errors=vkf_save_errors();if(scope.span.id)scope.span.end=vkf_qpc();
    vkf_sampled_result(&scope,result);vkf_sampled_end(&scope);scope.span.id=0;scope.counter.shard=NULL;
    vkf_restore_errors(errors);return result;
}
static inline int vkf_cond_wait(pthread_cond_t *cond,pthread_mutex_t *mutex,uint64_t site)
{
    struct vkf_errors errors;
    VKF_SCOPE(scope,VKF_COND_WAIT,cond,site,(uintptr_t)mutex);
    int result;
    errors=vkf_save_errors();if(scope.id)scope.start=vkf_qpc();vkf_restore_errors(errors);
    result=pthread_cond_wait(cond,mutex);errors=vkf_save_errors();if(scope.id)scope.end=vkf_qpc();
    vkf_result(&scope,result);vkf_end(&scope);scope.id=0;vkf_restore_errors(errors);return result;
}
#endif

#if defined(VKD3D_FORENSICS_IMPLEMENTATION) && defined(_WIN32)
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <inttypes.h>
#define VKF_RING_SIZE 4096
#define VKF_SHARDS 128
struct __attribute__((aligned(64))) vkf_copy_shard { volatile LONG64 calls,descriptors,samples,sampled_qpc; volatile LONG tid;uint32_t operation;
    unsigned char pad[24]; };
static struct {
    SRWLOCK ring_lock,map_lock;
    struct vkf_event ring[VKF_RING_SIZE];uint32_t head,tail;
    volatile LONG running,shard_count;
    volatile LONG64 session __attribute__((aligned(64)));
    unsigned char session_read_padding[56];
    volatile LONG64 next_id,offered,dropped,lock_drops,ring_drops,activity;
    volatile LONG64 copy_untracked,copy_untracked_descriptors;
    struct vkf_copy_shard shards[VKF_SHARDS];
    struct {uint64_t queue;uint32_t family,index;} maps[64];uint32_t map_count;
    uint64_t run_id,freq,sequence,generation,written,bytes,io_errors,rate_drops;
    uint64_t writer_qpc,last_summary_qpc,second,second_rows;
    HANDLE file;wchar_t out_dir[2048],config[2048];
} vkf_state={0};
_Thread_local struct vkf_context vkf_context={0};
static _Thread_local struct vkf_copy_shard *vkf_local_shard[5];
static _Thread_local uint64_t vkf_local_calls[5];
static _Thread_local int vkf_no_shard[5];
struct vkf_errors vkf_save_errors(void)
{ struct vkf_errors e={errno,GetLastError()};return e; }
void vkf_restore_errors(struct vkf_errors e) { SetLastError(e.last);errno=e.err; }
uint64_t vkf_qpc(void) { LARGE_INTEGER q;QueryPerformanceCounter(&q);return q.QuadPart; }
uint64_t vkf_next_id(void) { return InterlockedIncrement64(&vkf_state.next_id); }
static DWORD WINAPI vkf_writer(void *module);
static void vkf_boot(void)
{
    HMODULE module;HANDLE thread;struct vkf_errors errors=vkf_save_errors();
    InterlockedIncrement64(&vkf_state.activity);
    if(InterlockedCompareExchange(&vkf_state.running,1,0)==0) {
        if(GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                (LPCSTR)(uintptr_t)&vkf_boot,&module)) {
            thread=CreateThread(NULL,0,vkf_writer,module,0,NULL);
            if(thread)CloseHandle(thread);
            else {InterlockedExchange(&vkf_state.running,0);FreeLibrary(module);}
        } else InterlockedExchange(&vkf_state.running,0);
    }
    vkf_restore_errors(errors);
}
uint64_t vkf_peek_session(void)
{ return (uint64_t)__atomic_load_n(&vkf_state.session,__ATOMIC_ACQUIRE); }
uint64_t vkf_session(void)
{ vkf_boot();return vkf_peek_session(); }
void vkf_emit(uint32_t kind,uint32_t phase,uint64_t session,uint64_t id,uint64_t parent,
        uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t f,uint64_t g,uint64_t h)
{
    struct vkf_errors errors=vkf_save_errors();uint32_t next;
    if(!session){vkf_restore_errors(errors);return;}
    if(!__atomic_load_n(&vkf_state.running,__ATOMIC_ACQUIRE))vkf_boot();
    InterlockedIncrement64(&vkf_state.offered);
    if(!TryAcquireSRWLockExclusive(&vkf_state.ring_lock)) {
        InterlockedIncrement64(&vkf_state.lock_drops);InterlockedIncrement64(&vkf_state.dropped);
        vkf_restore_errors(errors);return;
    }
    next=(vkf_state.head+1)%VKF_RING_SIZE;
    if(next==vkf_state.tail) {
        InterlockedIncrement64(&vkf_state.ring_drops);InterlockedIncrement64(&vkf_state.dropped);
    } else {
        struct vkf_event *v=&vkf_state.ring[vkf_state.head];
        *v=(struct vkf_event){session,vkf_qpc(),id,parent,{a,b,c,d,e,f,g,h},kind,phase,GetCurrentThreadId()};
        vkf_state.head=next;
    }
    ReleaseSRWLockExclusive(&vkf_state.ring_lock);vkf_restore_errors(errors);
}
void vkf_queue_mapping(uint64_t queue,uint32_t family,uint32_t index)
{
    struct vkf_errors errors=vkf_save_errors();uint32_t i;
    if(TryAcquireSRWLockExclusive(&vkf_state.map_lock)) {
        for(i=0;i<vkf_state.map_count;++i)if(vkf_state.maps[i].queue==queue)break;
        if(i<64){vkf_state.maps[i].queue=queue;vkf_state.maps[i].family=family;
            vkf_state.maps[i].index=index;if(i==vkf_state.map_count)++vkf_state.map_count;}
        ReleaseSRWLockExclusive(&vkf_state.map_lock);
    }
    vkf_note(VKF_QUEUE_MAP,queue,family,index,0);
    vkf_restore_errors(errors);
}
void vkf_lookup_queue(uint64_t queue,uint32_t *family,uint32_t *index)
{
    struct vkf_errors errors=vkf_save_errors();uint32_t i;
    if(TryAcquireSRWLockShared(&vkf_state.map_lock)) {
        for(i=0;i<vkf_state.map_count;++i)if(vkf_state.maps[i].queue==queue){*family=vkf_state.maps[i].family;*index=vkf_state.maps[i].index;break;}
        ReleaseSRWLockShared(&vkf_state.map_lock);
    }
    vkf_restore_errors(errors);
}
struct vkf_copy_scope vkf_copy_begin(uint64_t descriptors,uint32_t heap_type,uint32_t variant)
{
    struct vkf_errors errors=vkf_save_errors();struct vkf_copy_scope s={0};LONG index;uint32_t op=variant>=257&&variant<=260?variant-256:0;
    ++vkf_local_calls[op];
    if((vkf_local_calls[op]&63)==0)vkf_boot();
    if(vkf_peek_session()) {
        if(!vkf_local_shard[op]&&!vkf_no_shard[op]) {
            index=InterlockedIncrement(&vkf_state.shard_count)-1;
            if(index<VKF_SHARDS){vkf_local_shard[op]=&vkf_state.shards[index];vkf_local_shard[op]->operation=op;InterlockedExchange(&vkf_local_shard[op]->tid,GetCurrentThreadId());}else vkf_no_shard[op]=1;
        }
        if(vkf_local_shard[op]) {
            __atomic_store_n(&vkf_local_shard[op]->calls,__atomic_load_n(&vkf_local_shard[op]->calls,__ATOMIC_RELAXED)+1,__ATOMIC_RELAXED);
            __atomic_store_n(&vkf_local_shard[op]->descriptors,__atomic_load_n(&vkf_local_shard[op]->descriptors,__ATOMIC_RELAXED)+descriptors,__ATOMIC_RELAXED);
            if((vkf_local_calls[op]&63)==0){s.shard=vkf_local_shard[op];s.start=vkf_qpc();}
        } else {InterlockedIncrement64(&vkf_state.copy_untracked);InterlockedAdd64(&vkf_state.copy_untracked_descriptors,descriptors);}
    }
    (void)heap_type;(void)variant;vkf_restore_errors(errors);return s;
}
void vkf_copy_end(struct vkf_copy_scope *s)
{
    struct vkf_errors errors=vkf_save_errors();
    if(s->shard){struct vkf_copy_shard *v=s->shard;
        __atomic_store_n(&v->sampled_qpc,__atomic_load_n(&v->sampled_qpc,__ATOMIC_RELAXED)+vkf_qpc()-s->start,__ATOMIC_RELAXED);
        __atomic_store_n(&v->samples,__atomic_load_n(&v->samples,__ATOMIC_RELAXED)+1,__ATOMIC_RELAXED);}
    vkf_restore_errors(errors);
}
static uint64_t vkf_filetime(FILETIME t) {return ((uint64_t)t.dwHighDateTime<<32)|t.dwLowDateTime;}
static unsigned vkf_precise_utc;
static void vkf_utc(FILETIME *time)
{
    typedef VOID (WINAPI *precise_fn)(LPFILETIME);
    static precise_fn precise;static int checked;
    if(!checked){precise=(precise_fn)(uintptr_t)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"GetSystemTimePreciseAsFileTime");checked=1;vkf_precise_utc=precise!=NULL;}
    if(precise)precise(time);else GetSystemTimeAsFileTime(time);
}

static int vkf_write(const char *text,size_t length)
{
    DWORD wrote=0;if(vkf_state.file==INVALID_HANDLE_VALUE){++vkf_state.io_errors;return 0;}
    if(!WriteFile(vkf_state.file,text,(DWORD)length,&wrote,NULL)||wrote!=length){++vkf_state.io_errors;return 0;}
    vkf_state.bytes+=length;return 1;
}
static void vkf_open(void)
{
    wchar_t path[2304];char row[1024];LARGE_INTEGER f;FILETIME ft;uint64_t before,after;
    if(vkf_state.file!=INVALID_HANDLE_VALUE)CloseHandle(vkf_state.file);
    ++vkf_state.generation;vkf_state.bytes=0;
    swprintf(path,2304,L"%ls\\vkd3d-forensics-%lu-%llu-%u.jsonl",vkf_state.out_dir,
            GetCurrentProcessId(),(unsigned long long)vkf_state.run_id,(unsigned)((vkf_state.generation-1)%4));
    vkf_state.file=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,CREATE_ALWAYS,0,NULL);
    if(vkf_state.file==INVALID_HANDLE_VALUE){++vkf_state.io_errors;return;}
    QueryPerformanceFrequency(&f);vkf_state.freq=f.QuadPart;
    before=vkf_qpc();vkf_utc(&ft);after=vkf_qpc();
    int n=snprintf(row,sizeof(row),"{\"schema\":1,\"type\":\"clockCalibration\",\"windowsPID\":%lu,\"runID\":%llu,\"streamGeneration\":%llu,\"session\":%llu,\"qpcBefore\":%llu,\"qpcAfter\":%llu,\"qpcFrequency\":%llu,\"fileTimeUTC100ns\":%llu,\"preciseUTCAPI\":%u,\"syntheticCPUControl\":%u,\"clockDomain\":\"windows-qpc\",\"threadIDDomain\":\"windows-guest-thread-id\",\"rollingSegmentSlots\":4}\n",GetCurrentProcessId(),(unsigned long long)vkf_state.run_id,(unsigned long long)vkf_state.generation,(unsigned long long)vkf_state.session,(unsigned long long)before,(unsigned long long)after,(unsigned long long)vkf_state.freq,(unsigned long long)vkf_filetime(ft),vkf_precise_utc,VKF_SYNTHETIC_CPU_CONTROL);
    if(n>0&&(size_t)n<sizeof(row))vkf_write(row,n);
    AcquireSRWLockShared(&vkf_state.map_lock);
    for(uint32_t i=0;i<vkf_state.map_count;++i)
        vkf_emit(VKF_QUEUE_MAP,2,vkf_state.session,vkf_next_id(),0,vkf_state.maps[i].queue,
                vkf_state.maps[i].family,vkf_state.maps[i].index,0,0,0,0,0);
    ReleaseSRWLockShared(&vkf_state.map_lock);
}
static void vkf_counter_summary(uint64_t session,unsigned final_boundary)
{
    char row[2048];uint64_t before=vkf_qpc();
    for(uint32_t i=0;i<VKF_SHARDS&&i<(uint32_t)vkf_state.shard_count;++i) {
        struct vkf_copy_shard *s=&vkf_state.shards[i];DWORD tid=(DWORD)__atomic_load_n(&s->tid,__ATOMIC_ACQUIRE);
        if(!tid)continue;
        int len=snprintf(row,sizeof(row),"{\"schema\":1,\"type\":\"%s\",\"runID\":%llu,\"streamGeneration\":%llu,\"session\":%llu,\"qpc\":%llu,\"windowsThreadID\":%lu,\"operation\":%u,\"offeredCalls\":%llu,\"%s\":%llu,\"sampledCalls\":%llu,\"sampledWallQPC\":%llu,\"samplePeriod\":64,\"shardIndex\":%u,\"finalBoundary\":%u,\"nonAtomicCumulativeSnapshot\":true,\"cumulativeSinceRunArmedCallsOnly\":true}\n",
            s->operation?"resourceAPICumulative":"copyCumulative",(unsigned long long)vkf_state.run_id,(unsigned long long)vkf_state.generation,(unsigned long long)session,(unsigned long long)before,tid,s->operation,
            (unsigned long long)__atomic_load_n(&s->calls,__ATOMIC_RELAXED),s->operation?"offeredUnits":"offeredDescriptors",(unsigned long long)__atomic_load_n(&s->descriptors,__ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&s->samples,__ATOMIC_RELAXED),(unsigned long long)__atomic_load_n(&s->sampled_qpc,__ATOMIC_RELAXED),i,final_boundary);
        if(vkf_state.bytes>8*1024*1024-2048)vkf_open();if(len>0&&(size_t)len<sizeof(row))vkf_write(row,len);
    }
}
static void vkf_disarm_summary(void)
{
    uint64_t old=(uint64_t)InterlockedExchange64(&vkf_state.session,0);
    if(old&&vkf_state.out_dir[0])vkf_counter_summary(old,1);
}
static void vkf_reload(void)
{
    char config[8192];DWORD bytes=0;HANDLE file;char *second,*end;wchar_t arm[2048],output[2048];WIN32_FILE_ATTRIBUTE_DATA attr;FILETIME now;
    uint64_t session=0;file=CreateFileW(vkf_state.config,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);
    if(file==INVALID_HANDLE_VALUE){vkf_disarm_summary();return;}
    if(!ReadFile(file,config,sizeof(config)-1,&bytes,NULL)){CloseHandle(file);vkf_disarm_summary();++vkf_state.io_errors;return;}CloseHandle(file);config[bytes]=0;
    second=strchr(config,'\n');if(!second){vkf_disarm_summary();return;}*second++=0;
    if((end=strpbrk(config,"\r\n")))*end=0;if((end=strpbrk(second,"\r\n")))*end=0;
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,config,-1,arm,2048)||
            !MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,second,-1,output,2048)){vkf_disarm_summary();return;}
    vkf_utc(&now);
    if(GetFileAttributesExW(arm,GetFileExInfoStandard,&attr)) {
        uint64_t stamp=vkf_filetime(attr.ftLastWriteTime),wall=vkf_filetime(now);
        if(!(attr.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)&&stamp<=wall&&wall-stamp<1200000000ULL)session=stamp;
    }
    if(vkf_state.session&&(session!=(uint64_t)vkf_state.session||wcscmp(output,vkf_state.out_dir))) {
        uint64_t old=vkf_state.session;InterlockedExchange64(&vkf_state.session,0);
        vkf_counter_summary(old,1);
    }
    if(session&&(session!=(uint64_t)vkf_state.session||wcscmp(output,vkf_state.out_dir))) {
        wcscpy(vkf_state.out_dir,output);InterlockedExchange64(&vkf_state.session,session);vkf_open();
    } else InterlockedExchange64(&vkf_state.session,session);
}
static void vkf_metadata(void)
{
    wchar_t path[2304],tmp[2304];char row[2048];DWORD wrote;HANDLE file;
    swprintf(path,2304,L"%ls\\vkd3d-forensics-current-%lu-%llu.json",vkf_state.out_dir,GetCurrentProcessId(),(unsigned long long)vkf_state.run_id);
    swprintf(tmp,2304,L"%ls.next",path);
    int n=snprintf(row,sizeof(row),"{\"schema\":1,\"windowsPID\":%lu,\"runID\":%llu,\"session\":%llu,\"streamGeneration\":%llu,\"offered\":%llu,\"written\":%llu,\"producerDropped\":%llu,\"lockDrops\":%llu,\"ringDrops\":%llu,\"rateDrops\":%llu,\"IOFailures\":%llu,\"writerQPC\":%llu,\"qpcFrequency\":%llu,\"copyUntrackedCalls\":%llu,\"copyUntrackedDescriptors\":%llu,\"ringCapacity\":4095,\"rowCapPerSecond\":8192,\"segmentSlots\":4,\"segmentBytes\":8388608,\"rollingMayReplaceUncollectedRows\":true,\"observerOverheadNotSubtracted\":true}\n",GetCurrentProcessId(),(unsigned long long)vkf_state.run_id,(unsigned long long)vkf_state.session,(unsigned long long)vkf_state.generation,(unsigned long long)vkf_state.offered,(unsigned long long)vkf_state.written,(unsigned long long)vkf_state.dropped,(unsigned long long)vkf_state.lock_drops,(unsigned long long)vkf_state.ring_drops,(unsigned long long)vkf_state.rate_drops,(unsigned long long)vkf_state.io_errors,(unsigned long long)vkf_state.writer_qpc,(unsigned long long)vkf_state.freq,(unsigned long long)vkf_state.copy_untracked,(unsigned long long)vkf_state.copy_untracked_descriptors);
    if(n<=0||(size_t)n>=sizeof(row))return;
    file=CreateFileW(tmp,GENERIC_WRITE,FILE_SHARE_READ,NULL,CREATE_ALWAYS,0,NULL);
    if(file==INVALID_HANDLE_VALUE){++vkf_state.io_errors;return;}
    BOOL ok=WriteFile(file,row,n,&wrote,NULL);CloseHandle(file);
    if(!ok||wrote!=(DWORD)n||!MoveFileExW(tmp,path,MOVEFILE_REPLACE_EXISTING))++vkf_state.io_errors;
}
static DWORD WINAPI vkf_writer(void *module)
{
    struct vkf_event events[256];wchar_t *slash;FILETIME ft;LARGE_INTEGER freq;DWORD module_length;
    uint64_t last_activity=0,idle_since;uint32_t i,n;char row[2048];
    QueryPerformanceFrequency(&freq);vkf_state.freq=freq.QuadPart;
    if(!vkf_state.run_id){GetSystemTimeAsFileTime(&ft);vkf_state.run_id=vkf_filetime(ft)^vkf_qpc();}
    vkf_state.file=INVALID_HANDLE_VALUE;
    module_length=GetModuleFileNameW(module,vkf_state.config,2048);
    if(!module_length||module_length>=2048)vkf_state.config[0]=0;
    slash=wcsrchr(vkf_state.config,L'\\');
    if(slash&&(size_t)(slash-vkf_state.config)+1+wcslen(L"vkd3d-forensics-paths.txt")<2048)
        wcscpy(slash+1,L"vkd3d-forensics-paths.txt");
    else vkf_state.config[0]=0;
    idle_since=vkf_qpc();
    for(;;) {
        uint64_t before=vkf_qpc(),activity=InterlockedCompareExchange64(&vkf_state.activity,0,0);
        if(activity!=last_activity){last_activity=activity;idle_since=before;}
        vkf_reload();
        if(vkf_state.file==INVALID_HANDLE_VALUE&&vkf_state.out_dir[0]&&vkf_state.head!=vkf_state.tail)vkf_open();
        do {
            AcquireSRWLockExclusive(&vkf_state.ring_lock);n=0;
            while(vkf_state.tail!=vkf_state.head&&n<256){events[n++]=vkf_state.ring[vkf_state.tail];vkf_state.tail=(vkf_state.tail+1)%VKF_RING_SIZE;}
            ReleaseSRWLockExclusive(&vkf_state.ring_lock);
            for(i=0;i<n;++i) {
                const struct vkf_event *v=&events[i];uint64_t second=v->qpc/vkf_state.freq;
                if(second!=vkf_state.second){vkf_state.second=second;vkf_state.second_rows=0;}
                if(++vkf_state.second_rows>8192){++vkf_state.rate_drops;continue;}
                if(vkf_state.bytes>8*1024*1024-2048)vkf_open();
                int len=snprintf(row,sizeof(row),"{\"schema\":1,\"type\":\"event\",\"windowsPID\":%lu,\"runID\":%llu,\"streamGeneration\":%llu,\"session\":%llu,\"seq\":%llu,\"qpc\":%llu,\"windowsThreadID\":%u,\"kind\":%u,\"phase\":%u,\"id\":%llu,\"parent\":%llu,\"args\":[%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu]}\n",GetCurrentProcessId(),(unsigned long long)vkf_state.run_id,(unsigned long long)vkf_state.generation,(unsigned long long)v->session,(unsigned long long)++vkf_state.sequence,(unsigned long long)v->qpc,v->tid,v->kind,v->phase,(unsigned long long)v->id,(unsigned long long)v->parent,(unsigned long long)v->a[0],(unsigned long long)v->a[1],(unsigned long long)v->a[2],(unsigned long long)v->a[3],(unsigned long long)v->a[4],(unsigned long long)v->a[5],(unsigned long long)v->a[6],(unsigned long long)v->a[7]);
                if(len>0&&(size_t)len<sizeof(row)&&vkf_write(row,len))++vkf_state.written;
            }
        }while(n==256);
        if(vkf_state.session&&before-vkf_state.last_summary_qpc>=vkf_state.freq) {
            vkf_state.last_summary_qpc=before;
            vkf_counter_summary(vkf_state.session,0);
        }
        if(vkf_state.out_dir[0])vkf_metadata();
        vkf_state.writer_qpc+=vkf_qpc()-before;
        if(!vkf_state.session&&before-idle_since>vkf_state.freq*2)break;
        Sleep(250);
    }
    if(vkf_state.file!=INVALID_HANDLE_VALUE)CloseHandle(vkf_state.file);
    InterlockedExchange(&vkf_state.running,0);
    FreeLibraryAndExitThread(module,0);return 0;
}
#endif
#if defined(VKD3D_FORENSICS_IMPLEMENTATION) && !defined(_WIN32)
_Thread_local struct vkf_context vkf_context={0};
uint64_t vkf_session(void){return 0;}
uint64_t vkf_peek_session(void){return 0;}
uint64_t vkf_qpc(void){return 0;}
uint64_t vkf_next_id(void){return 0;}
struct vkf_errors vkf_save_errors(void){return (struct vkf_errors){errno,0};}
void vkf_restore_errors(struct vkf_errors e){errno=e.err;}
void vkf_emit(uint32_t k,uint32_t p,uint64_t s,uint64_t i,uint64_t parent,
        uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t f,uint64_t g,uint64_t h){}
struct vkf_copy_scope vkf_copy_begin(uint64_t n,uint32_t h,uint32_t v){return (struct vkf_copy_scope){0};}
void vkf_copy_end(struct vkf_copy_scope *s){}
void vkf_queue_mapping(uint64_t q,uint32_t f,uint32_t i){}
void vkf_lookup_queue(uint64_t q,uint32_t *f,uint32_t *i){}
#endif
#endif


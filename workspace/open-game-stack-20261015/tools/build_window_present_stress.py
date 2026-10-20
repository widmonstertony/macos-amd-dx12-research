#!/usr/bin/env python3
"""Derive an isolated concurrency test from the real-pixel presentation probe."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
OUT = ROOT / 'evidence/window-present-lock-20261019'
OUT.mkdir(exist_ok=True)
source = (REPO / 'presentation-probe/d3d12_presentation_probe.cpp').read_text()
source = source.replace('#include "../d3d12_probe.cpp"', '#include "' + str(REPO / 'd3d12_probe.cpp') + '"')
source = source.replace('#include "../graphics-probe/d3d12_graphics_probe.cpp"', '#include "' + str(REPO / 'graphics-probe/d3d12_graphics_probe.cpp') + '"')
insert = r'''
struct StressContext { Com *swap; U32 done, count; HR result; };
static U32 __stdcall present_worker(void *opaque) {
    auto *state=static_cast<StressContext *>(opaque);
    state->result=0;
    for(U32 i=0;i<900;++i) {
        HR result=method<HR (__stdcall *)(Com *,U32,U32)>(state->swap,8)(state->swap,0,0);
        if(result<0) {state->result=result;break;}
        __atomic_store_n(&state->count,i+1,__ATOMIC_RELAXED);
        Sleep(4);
    }
    __atomic_store_n(&state->done,1,__ATOMIC_RELEASE);
    return 0;
}
static bool concurrent_present_test(Com *swap,Handle hwnd) {
    Handle kernel=LoadLibraryW(L"kernel32.dll"),user=LoadLibraryW(L"user32.dll");
    auto createThread=reinterpret_cast<Handle (__stdcall *)(void *,Size,U32 (__stdcall *)(void *),void *,U32,U32 *)>(GetProcAddress(kernel,"CreateThread"));
    auto wait=reinterpret_cast<U32 (__stdcall *)(Handle,U32)>(GetProcAddress(kernel,"WaitForSingleObject"));
    auto close=reinterpret_cast<I32 (__stdcall *)(Handle)>(GetProcAddress(kernel,"CloseHandle"));
    auto setPos=reinterpret_cast<I32 (__stdcall *)(Handle,Handle,I32,I32,I32,I32,U32)>(GetProcAddress(user,"SetWindowPos"));
    auto setTitle=reinterpret_cast<I32 (__stdcall *)(Handle,const wchar_t *)>(GetProcAddress(user,"SetWindowTextW"));
    if(!createThread||!wait||!close||!setPos) return false;
    StressContext state={swap,0,0,0};
    if(setTitle) setTitle(hwnd,L"D3D12 Intel presentation probe - stress active");
    Handle thread=createThread(nullptr,0,present_worker,&state,0,nullptr);
    if(!thread) return false;
    U32 resizes=0;
    for(U32 i=0;i<2000&&!__atomic_load_n(&state.done,__ATOMIC_ACQUIRE);++i) {
#ifndef STRESS_NO_RESIZE
        if(!setPos(hwnd,nullptr,150+(i%2)*5,150,288+(i%2)*32,320+(i%3)*16,0x0014)) return false;
        ++resizes;
#endif
        pump_messages();
        if(i%100==0) {text("stress.present_count=");number(__atomic_load_n(&state.count,__ATOMIC_RELAXED));text(" resizes=");number(resizes);text("\n");}
        Sleep(5);
    }
    // Do not unwind a stack still referenced by the worker on timeout.
    // done is published just before the worker returns. Wine's thread cleanup
    // can still be running; a zero-time join here incorrectly reports failure.
    for(U32 i=0;i<400&&wait(thread,0)!=0;++i) {pump_messages();Sleep(5);}
    if(wait(thread,0)!=0) {text("stress.TIMEOUT\n");ExitProcess(21);}
    close(thread);
    text("stress.final_present_count=");number(state.count);text(" resizes=");number(resizes);text("\n");
    hr("stress.present_result",state.result);
    return state.done&&state.count==900&&state.result>=0;
}
'''
source=source.replace('static bool window_presentation(', insert+'\nstatic bool window_presentation(',1)
old='for(U32 i=0;i<500;++i) {pump_messages();Sleep(10);}\n        pass=true;'
assert old in source
draw='GTextureBarrier prepare='+source.split('GTextureBarrier prepare=',1)[1].split('if(!need("presentation.DXGI_Present"',1)[0]
draw=draw.replace('fence,1)', 'fence,4)').replace('wait_fence(fence,1)', 'wait_fence(fence,4)')
post=r'''
        if(!concurrent_present_test(swap,hwnd)) goto cleanup;
        if(!need("stress.SignalDrain",method<HR (__stdcall *)(Com *,Com *,U64)>(queue,14)(queue,fence,3)) || !wait_fence(fence,3)) goto cleanup;
        release(backbuffer);backbuffer=nullptr;
        U32 finalIndex=method<U32 (__stdcall *)(Com *)>(swap3,36)(swap3);
        if(!need("stress.GetFinalBuffer",method<HR (__stdcall *)(Com *,U32,const Guid *,Com **)>(swap,9)(swap,finalIndex,&IID_Resource,&backbuffer))) goto cleanup;
        method<void (__stdcall *)(Com *,Com *,const void *,GCpuHandle)>(device,20)(device,backbuffer,nullptr,rtv);
        if(!need("stress.ResetAllocator",method<HR (__stdcall *)(Com *)>(allocator,8)(allocator))) goto cleanup;
        if(!need("stress.ResetList",method<HR (__stdcall *)(Com *,Com *,Com *)>(list,10)(list,allocator,pso))) goto cleanup;
        {
'''+draw+r'''
        }
        if(!need("stress.FinalPresent",method<HR (__stdcall *)(Com *,U32,U32)>(swap,8)(swap,1,0))) goto cleanup;
        if(!need("stress.FinalSignal",method<HR (__stdcall *)(Com *,Com *,U64)>(queue,14)(queue,fence,5)) || !wait_fence(fence,5)) goto cleanup;
        text("stress.after_contention_pixels=PASS\n");
        pass=true;
'''
source=source.replace(old,post)
(OUT/'window_present_stress.cpp').write_text(source)
llvm=Path('/usr/local/Cellar/llvm@20/20.1.8/bin')
for mode,flags in [('control',['-DSTRESS_NO_RESIZE']),('resize',[])]:
    obj=OUT/f'{mode}.obj'
    subprocess.run([str(llvm/'clang++'),'--target=x86_64-pc-windows-msvc','-std=c++17','-O1','-Wall','-Wextra','-fno-exceptions','-fno-rtti','-fno-stack-protector','-ffreestanding',*flags,'-c',str(OUT/'window_present_stress.cpp'),'-o',str(obj)],check=True)
    subprocess.run(['/usr/local/bin/lld-link','/nologo','/entry:mainCRTStartup','/subsystem:console','/machine:x64','/nodefaultlib',f'/out:{OUT}/{mode}.exe',str(obj),str(REPO/'d3d12_probe_kernel32.lib'),str(REPO/'presentation-probe/presentation_user32.lib')],check=True)
print(OUT)

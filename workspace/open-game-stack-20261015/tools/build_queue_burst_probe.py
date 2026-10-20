#!/usr/bin/env python3
"""Extend the known real-GPU queue fixture to bounded, pipelined submissions.

Every GPU signal is ordered after its predecessor; no intentionally missing
signal or artificial hang is submitted. Readback checks all sixteen slots.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'evidence/queue-burst-20261020'
OUT.mkdir(exist_ok=True)
text = (ROOT / 'src/queue_sync_probe.cpp').read_text()


def replace(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


replace('VkCommandBuffer commands[3];', 'constexpr uint32_t window=16; VkCommandBuffer commands[3][window];')
replace('ai.commandBufferCount=1;CHECK(vkAllocateCommandBuffers(device,&ai,&commands[i]));',
        'ai.commandBufferCount=window;CHECK(vkAllocateCommandBuffers(device,&ai,commands[i]));')
replace('constexpr uint32_t words=4096,rounds=64;', 'constexpr uint32_t words=4096,rounds=2048;')
replace('bi.size=words*4;', 'bi.size=words*4*window;')
replace('for(unsigned i=0;i<3;++i){CHECK(vkResetCommandPool(device,pools[i],0));',
        'VkDeviceSize offset=(round%window)*words*4;for(unsigned i=0;i<3;++i){if(round%window==0)CHECK(vkResetCommandPool(device,pools[i],0)); VkCommandBuffer command=commands[i][round%window];')
text = text.replace('vkBeginCommandBuffer(commands[i],', 'vkBeginCommandBuffer(command,')
text = text.replace('vkCmdFillBuffer(commands[i],buffers[0],0,', 'vkCmdFillBuffer(command,buffers[0],offset,')
text = text.replace('VkBufferCopy copy{0,0,words*4};', 'VkBufferCopy copy{offset,offset,words*4};')
text = text.replace('vkCmdCopyBuffer(commands[i],', 'vkCmdCopyBuffer(command,')
text = text.replace('vkCmdPipelineBarrier(commands[i],', 'vkCmdPipelineBarrier(command,')
text = text.replace('vkEndCommandBuffer(commands[i])', 'vkEndCommandBuffer(command)')
text = text.replace('i?1:0', '(i||round)?1:0')
text = text.replace('i?&wait:nullptr', '(i||round)?&wait:nullptr')
text = text.replace('i?&timeline:nullptr', '(i||round)?&timeline:nullptr')
text = text.replace('i?&waitStage:nullptr', '(i||round)?&waitStage:nullptr')
replace('submit.pCommandBuffers=&commands[i];', 'submit.pCommandBuffers=&command;')
replace('uint64_t target=first+2;', 'if(round%window!=window-1)continue; uint64_t target=first+2;')
replace('auto*data=(uint32_t*)maps[2];for(uint32_t k=0;k<words;++k){++checked;if(data[k]!=pattern)++bad;}',
        'auto*data=(uint32_t*)maps[2];for(uint32_t slot=0;slot<window;++slot){uint32_t expected=0x10203040u^((round-window+1+slot)*0x01010101u);for(uint32_t k=0;k<words;++k){++checked;if(data[slot*words+k]!=expected)++bad;}}')
source = OUT / 'queue_burst_probe.cpp'
source.write_text(text)
include = ROOT / 'native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a/include'
loader = Path('/usr/local/lib/libvulkan.dylib')
assert loader.is_file()
subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', '-I', str(ROOT/'src'),
                '-I', str(include), str(source), str(loader), '-o', str(OUT/'queue_burst_probe')], check=True)
print(OUT)

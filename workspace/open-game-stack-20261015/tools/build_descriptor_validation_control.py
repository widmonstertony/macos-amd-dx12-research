#!/usr/bin/env python3
"""Build the owned UAV-table regression; never deploy or start an application."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--compiler', default=shutil.which('clang++'))
parser.add_argument('--linker', default=shutil.which('lld-link'))
args = parser.parse_args()
assert args.compiler and args.linker, 'clang++ and lld-link are required'
source = ROOT / 'src/d3d12_descriptor_validation_control.cpp'
output = ROOT / 'build/descriptor-validation-control.exe'
output.parent.mkdir(exist_ok=True)
obj = output.with_suffix('.obj')
subprocess.run([args.compiler, '--target=x86_64-pc-windows-msvc', '-std=c++17',
                '-O1', '-Wall', '-Wextra', '-fno-exceptions', '-fno-rtti',
                '-fno-stack-protector', '-ffreestanding', '-c', str(source),
                '-o', str(obj)], check=True)
subprocess.run([args.linker, '/nologo', '/entry:mainCRTStartup',
                '/subsystem:console', '/machine:x64', '/nodefaultlib',
                '/out:' + str(output), str(obj),
                str(ROOT.parent / 'd3d12_probe_kernel32.lib')], check=True)
print(json.dumps({'output': str(output),
                  'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                  'applicationStarted': False}))

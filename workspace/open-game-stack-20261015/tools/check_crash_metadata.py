#!/usr/bin/env python3
"""Run the file-API regression and the reporter's help in the original Wine."""
import ast
import json
import os
import subprocess
from pathlib import Path
import qualify_late_guard as qualified

ROOT = qualified.ROOT
OUT = ROOT / 'evidence/winemac-compat-20261019'
tree = ast.parse((ROOT / 'tools/qualify_late_guard.py').read_text())
main = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'main')
update = next(n for n in main.body if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
              and isinstance(n.value.func, ast.Attribute) and n.value.func.attr == 'update')
def environment():
    env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'WINE', 'YYB_', 'VK_', 'VKD3D_', 'DXVK_', 'MVK_'))}
    env.update(eval(compile(ast.Expression(update.value), 'qualified-environment', 'eval'),
                    qualified.__dict__ | {'env': env}) or {})
    env['DYLD_LIBRARY_PATH'] = str(ROOT / 'build/winemac-lockfix-leaf-select') + ':' + env['DYLD_LIBRARY_PATH']
    return env


def main():
    results = {}
    for name, arguments in [
        ('crash-metadata-api', [str(OUT / 'crash_metadata_probe.exe')]),
        ('crash-reporter-help', [str(ROOT.parent / 'stellar-overlay/crs-handler.exe'), '--help']),
    ]:
        with (OUT / (name + '.stdout.log')).open('w') as stdout, (OUT / (name + '.stderr.log')).open('w') as stderr:
            p = subprocess.Popen([str(qualified.SUPPORT / 'wine-loader'), *arguments],
                                 cwd=ROOT.parent / 'stellar-overlay', env=environment(),
                                 stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                code = p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                p.terminate()
                code = p.wait(timeout=5)
            results[name] = {'pid': p.pid, 'exitCode': code}
        if name == 'crash-metadata-api':
            log = (OUT / (name + '.stdout.log')).read_text(errors='replace')
            results[name]['passed'] = code == 0 and 'metadata.result=PASS' in log
            print(log)
    (OUT / 'crash-metadata-api.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()

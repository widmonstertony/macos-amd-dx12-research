#!/usr/bin/env python3
"""Build and run the bounded consumer-first cross-queue timeline control."""
import argparse, hashlib, json, os, pathlib, plistlib, re, shlex, shutil, subprocess, time

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--library", type=pathlib.Path, required=True)
parser.add_argument("--label", required=True)
args = parser.parse_args()
library = args.library.resolve()
if not library.is_relative_to(root / "build") or not library.is_file():
    parser.error("Owned candidate under build/ required")
if not re.fullmatch(r"[a-z0-9-]{1,64}", args.label):
    parser.error("Safe unique label required")

out = root / "evidence" / args.label
out.mkdir(exist_ok=False)
(out / "msl").mkdir()
app = out / "QueuePingPong.app"
macos = app / "Contents" / "MacOS"
frameworks = app / "Contents" / "Frameworks"
resources = app / "Contents" / "Resources"
macos.mkdir(parents=True)
frameworks.mkdir()
resources.mkdir()
binary = macos / "queue_ping_pong"
subprocess.run([
    "clang++", "-std=c++17", "-O2", "-I", str(root / "src"),
    "-I", str(root / "native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a/include"),
    str(root / "src/queue_ping_pong_probe.cpp"), "/usr/local/lib/libvulkan.dylib", "-o", str(binary),
], check=True)
bundled = frameworks / "libCandidate.dylib"
shutil.copy2(library, bundled)
icd = resources / "icd.json"
icd.write_text(json.dumps({"file_format_version": "1.0.0", "ICD": {
    "library_path": str(bundled), "api_version": "1.4.0", "is_portability_driver": True}}))
env = {
    "VK_ICD_FILENAMES": str(icd),
    "MTL_DEBUG_LAYER": "1",
    "MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES": "1",
    "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS": "0",
    "MVK_CONFIG_USE_MTLHEAP": "2",
    "MVK_AMD_QUEUE_FAILURE_CONTEXT": "1",
    "MVK_AMD_RUNTIME_TRACE": "1",
    "MVK_CONFIG_SHADER_DUMP_DIR": str(out / "msl"),
}
runner = macos / "run-probe"
exports = "\n".join("export " + k + "=" + shlex.quote(v) for k, v in env.items())
runner.write_text("#!/bin/zsh\n" + exports + "\nexec " + shlex.quote(str(binary)) + " \"$@\"\n")
runner.chmod(0o755)
with (app / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump({
        "CFBundleExecutable": "run-probe",
        "CFBundleIdentifier": "local.openstack.queue-ping-pong." + args.label,
        "CFBundleName": "QueuePingPong",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "NSSupportsAutomaticGraphicsSwitching": False,
    }, stream)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
report = out / "output.json"
start = time.monotonic()
with (out / "stdout.log").open("w") as stdout, (out / "stderr.log").open("w") as stderr:
    launched = subprocess.run(["open", "-n", str(app), "--args", str(report)],
                              stdout=stdout, stderr=stderr, timeout=10)
deadline = time.monotonic() + 90
payload = None
while time.monotonic() < deadline:
    try:
        if report.stat().st_size:
            payload = json.loads(report.read_text())
            break
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    time.sleep(0.1)
if payload is None:
    raise subprocess.TimeoutExpired(str(app), 90)
record = {
    "nativeSHA256": hashlib.sha256(library.read_bytes()).hexdigest(),
    "consumerSubmittedBeforeProducer": True,
    "mutualQueueDependency": True,
    "metalValidation": True,
    "openExitCode": launched.returncode,
    "elapsedSeconds": time.monotonic() - start,
    "output": payload,
    "passed": launched.returncode == 0 and payload.get("passed", False),
    "gameStarted": False,
}
(out / "run.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record))
raise SystemExit(0 if record["passed"] else 1)

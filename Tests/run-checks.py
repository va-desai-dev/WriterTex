#!/usr/bin/env python3
"""Compile and run native checks against an existing Debug build of WriterTex.

Usage: python3 Tests/run-checks.py <DerivedData> [CheckFile.swift ...]

With no check files, runs every `*Checks.swift` in this folder. Each check is
compiled with `Support/*.swift`, linked against `WriterTex.debug.dylib`, and
launched from a throwaway app bundle whose Resources point at the built app's,
so bundled JSON and assets load. Each runs with its own temporary home folder
(`CFFIXED_USER_HOME`), so the project library in Documents, preferences and
recents never touch the real account.
Some checks open windows, so run from a logged-in macOS GUI session. Build first:

    xcodebuild -project WriterTex.xcodeproj -scheme WriterTex -configuration Debug \\
      -derivedDataPath <DerivedData> CODE_SIGNING_ALLOWED=NO build
"""
import os
import pathlib
import platform
import plistlib
import subprocess
import sys
import tempfile

TIMEOUT = 180

tests = pathlib.Path(__file__).resolve().parent
derived = pathlib.Path(sys.argv[1]).resolve()
build = derived / "Build"
packages = derived / "SourcePackages"
products = build / "Products/Debug"
app_bundle = products / "WriterTex.app"
with (app_bundle / "Contents/Info.plist").open("rb") as info:
    deployment_target = plistlib.load(info)["LSMinimumSystemVersion"]
dylibs = app_bundle / "Contents/MacOS"
checks = sys.argv[2:] or sorted(path.name for path in tests.glob("*Checks.swift"))

work = pathlib.Path(tempfile.mkdtemp(prefix="writertex-checks-", dir="/tmp"))
module_maps = list((build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"))


def compile_and_run(check: str) -> str:
    name = pathlib.Path(check).stem
    bundle = work / f"{name}.app"
    macos = bundle / "Contents/MacOS"
    macos.mkdir(parents=True)
    (bundle / "Contents/Resources").symlink_to(app_bundle / "Contents/Resources")
    with (bundle / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleExecutable": name, "CFBundleIdentifier": f"test.WriterTex.{name}",
                       "CFBundleName": name, "CFBundlePackageType": "APPL"}, output)
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
               "-target", f"{platform.machine()}-apple-macos{deployment_target}",
               "-module-cache-path", str(work / "ModuleCache"), "-I", str(products),
               "-Xcc", "-I" + str(packages / "checkouts/libgit2/include")]
    for module_map in module_maps:
        command += ["-Xcc", "-fmodule-map-file=" + str(module_map)]
    command += [str(tests / check), *map(str, sorted((tests / "Support").glob("*.swift"))),
                str(dylibs / "WriterTex.debug.dylib"),
                "-Xlinker", "-rpath", "-Xlinker", str(dylibs),
                "-Xlinker", "-rpath", "-Xlinker", str(products / "PackageFrameworks"),
                "-o", str(macos / name)]
    if subprocess.run(command).returncode != 0:
        return "compile failed"
    try:
        home = work / f"{name}-home"
        home.mkdir()
        environment = dict(os.environ, CFFIXED_USER_HOME=str(home))
        result = subprocess.run([str(macos / name)], timeout=TIMEOUT, env=environment)
    except subprocess.TimeoutExpired:
        return f"timed out after {TIMEOUT}s"
    return "passed" if result.returncode == 0 else f"failed (exit {result.returncode})"


results = {}
for check in checks:
    print(f"\n=== {check}", flush=True)
    results[check] = compile_and_run(check)
    print(f"=== {check}: {results[check]}", flush=True)

print("\nSummary")
for check, outcome in results.items():
    print(f"  {outcome:<24} {check}")
sys.exit(0 if all(outcome == "passed" for outcome in results.values()) else 1)

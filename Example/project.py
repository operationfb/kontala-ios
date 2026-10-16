"""Writes KontalaShop.xcodeproj: the demo shop on the local Kontala package, and the UI tests that walk through it.

The project is generated rather than kept by hand, so that what it holds is reviewable here: run
`python3 project.py` in sdk/ios/Example after adding a source file, and commit what it writes.

`python3 project.py --package-url URL --package-version V --out DIR` writes the same shop into DIR instead, on the
package a release published at URL, tag V, as an app names it: scripts/ios-release.sh builds it against the release it
is about to push, and against the public mirror once it has.
"""
import argparse
import hashlib
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.dirname(HERE)

parser = argparse.ArgumentParser()
parser.add_argument("--package-url", help="a released package's repository, in place of the package beside the shop")
parser.add_argument("--package-version", help="the release's tag, which the project names exactly")
parser.add_argument("--out", default=HERE, help="where the project is written, the shop's own folder by default")
args = parser.parse_args()
if bool(args.package_url) != bool(args.package_version):
    parser.error("--package-url and --package-version go together")
OUT = os.path.abspath(args.out)


def quoted(path):
    return path if all(c.isalnum() or c in "._/" for c in path) else f'"{path}"'


def oid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


app_sources = sorted(f for f in os.listdir(os.path.join(HERE, "KontalaShop")) if f.endswith(".swift"))
test_sources = sorted(f for f in os.listdir(os.path.join(HERE, "KontalaShopUITests")) if f.endswith(".swift"))

ids = {k: oid(k) for k in [
    "project", "main_group", "products_group", "app_group", "tests_group",
    "app_target", "test_target", "app_product", "test_product",
    "app_sources_phase", "app_frameworks_phase", "app_resources_phase",
    "test_sources_phase", "test_frameworks_phase",
    "project_config_list", "app_config_list", "test_config_list",
    "project_debug", "project_release", "app_debug", "app_release", "test_debug", "test_release",
    "package_ref", "package_dep", "package_build_file", "proxy", "dependency", "info_plist",
]}
for f in app_sources + test_sources:
    ids["file_" + f] = oid("file_" + f)
    ids["build_" + f] = oid("build_" + f)

rel = os.path.relpath(SDK, HERE)
# The sources: beside the project, or where they are for a project written elsewhere.
if OUT == HERE:
    app_dir, tests_dir, tree = "KontalaShop", "KontalaShopUITests", "<group>"
else:
    app_dir, tests_dir, tree = os.path.join(HERE, "KontalaShop"), os.path.join(HERE, "KontalaShopUITests"), "<absolute>"

common = {
    "SDKROOT": "iphoneos",
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1",
    "CODE_SIGN_IDENTITY": '"-"',
    "CODE_SIGN_STYLE": "Manual",
    "DEVELOPMENT_TEAM": '""',
}


def settings(extra, debug):
    s = dict(common)
    s.update(extra)
    s["SWIFT_OPTIMIZATION_LEVEL"] = '"-Onone"' if debug else '"-O"'
    if debug:
        s["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        s["DEBUG_INFORMATION_FORMAT"] = "dwarf"
        s["ONLY_ACTIVE_ARCH"] = "YES"
    return "{\n" + "".join(f"\t\t\t\t{k} = {v};\n" for k, v in sorted(s.items())) + "\t\t\t}"


app_settings = {
    "PRODUCT_BUNDLE_IDENTIFIER": "la.konta.example.shop",
    # What the shop sends to and shows, each overridden on xcodebuild's command line as KONTALA_COLLECTOR=... is:
    # the worktree's collector-file on port 8788 with its demo key, and the repository served on port 4173, both of
    # which the simulator reaches as localhost.
    "KONTALA_COLLECTOR": '"http://localhost:8788"',
    "KONTALA_WRITE_KEY": "pk_live_demo_000000000000000000000000",
    "KONTALA_WEBSITE": '"http://localhost:4173"',
    "KONTALA_WEBVIEW": "attached",
    "KONTALA_SESSION_MINUTES": "30",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "INFOPLIST_FILE": quoted(app_dir + "/Info.plist"),
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "ASSETCATALOG_COMPILER_APPICON_NAME": '""',
}
test_settings = {
    "PRODUCT_BUNDLE_IDENTIFIER": "la.konta.example.shop.uitests",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "GENERATE_INFOPLIST_FILE": "YES",
    "TEST_TARGET_NAME": "KontalaShop",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks @loader_path/Frameworks"',
}

o = []
o.append("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 60;\n\tobjects = {\n")

o.append("/* Begin PBXBuildFile section */\n")
for f in app_sources + test_sources:
    o.append(f"\t\t{ids['build_' + f]} = {{isa = PBXBuildFile; fileRef = {ids['file_' + f]}; }};\n")
o.append(f"\t\t{ids['package_build_file']} = {{isa = PBXBuildFile; productRef = {ids['package_dep']}; }};\n")
o.append("/* End PBXBuildFile section */\n\n")

o.append("/* Begin PBXContainerItemProxy section */\n")
o.append(f"\t\t{ids['proxy']} = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {ids['project']};\n"
         f"\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {ids['app_target']};\n\t\t\tremoteInfo = KontalaShop;\n\t\t}};\n")
o.append("/* End PBXContainerItemProxy section */\n\n")

o.append("/* Begin PBXFileReference section */\n")
for f in app_sources + test_sources:
    o.append(f"\t\t{ids['file_' + f]} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = \"<group>\"; }};\n")
o.append(f"\t\t{ids['info_plist']} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};\n")
o.append(f"\t\t{ids['app_product']} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = KontalaShop.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
o.append(f"\t\t{ids['test_product']} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = KontalaShopUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
o.append("/* End PBXFileReference section */\n\n")

o.append("/* Begin PBXFrameworksBuildPhase section */\n")
o.append(f"\t\t{ids['app_frameworks_phase']} = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
         f"\t\t\tfiles = (\n\t\t\t\t{ids['package_build_file']},\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
o.append(f"\t\t{ids['test_frameworks_phase']} = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
         f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
o.append("/* End PBXFrameworksBuildPhase section */\n\n")

o.append("/* Begin PBXGroup section */\n")
o.append(f"\t\t{ids['main_group']} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ids['app_group']},\n"
         f"\t\t\t\t{ids['tests_group']},\n\t\t\t\t{ids['products_group']},\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
o.append(f"\t\t{ids['products_group']} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ids['app_product']},\n"
         f"\t\t\t\t{ids['test_product']},\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
children = "".join(f"\t\t\t\t{ids['file_' + f]},\n" for f in app_sources) + f"\t\t\t\t{ids['info_plist']},\n"
o.append(f"\t\t{ids['app_group']} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n"
         f"\t\t\tpath = {quoted(app_dir)};\n\t\t\tsourceTree = \"{tree}\";\n\t\t}};\n")
children = "".join(f"\t\t\t\t{ids['file_' + f]},\n" for f in test_sources)
o.append(f"\t\t{ids['tests_group']} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n"
         f"\t\t\tpath = {quoted(tests_dir)};\n\t\t\tsourceTree = \"{tree}\";\n\t\t}};\n")
o.append("/* End PBXGroup section */\n\n")

o.append("/* Begin PBXNativeTarget section */\n")
o.append(f"\t\t{ids['app_target']} = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {ids['app_config_list']};\n"
         f"\t\t\tbuildPhases = (\n\t\t\t\t{ids['app_sources_phase']},\n\t\t\t\t{ids['app_frameworks_phase']},\n"
         f"\t\t\t\t{ids['app_resources_phase']},\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n"
         f"\t\t\tname = KontalaShop;\n\t\t\tpackageProductDependencies = (\n\t\t\t\t{ids['package_dep']},\n\t\t\t);\n"
         f"\t\t\tproductName = KontalaShop;\n\t\t\tproductReference = {ids['app_product']};\n"
         f"\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};\n")
o.append(f"\t\t{ids['test_target']} = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {ids['test_config_list']};\n"
         f"\t\t\tbuildPhases = (\n\t\t\t\t{ids['test_sources_phase']},\n\t\t\t\t{ids['test_frameworks_phase']},\n\t\t\t);\n"
         f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t{ids['dependency']},\n\t\t\t);\n"
         f"\t\t\tname = KontalaShopUITests;\n\t\t\tproductName = KontalaShopUITests;\n\t\t\tproductReference = {ids['test_product']};\n"
         f"\t\t\tproductType = \"com.apple.product-type.bundle.ui-testing\";\n\t\t}};\n")
o.append("/* End PBXNativeTarget section */\n\n")

o.append("/* Begin PBXProject section */\n")
o.append(f"\t\t{ids['project']} = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
         f"\t\t\t\tLastSwiftUpdateCheck = 1640;\n\t\t\t\tLastUpgradeCheck = 1640;\n\t\t\t\tTargetAttributes = {{\n"
         f"\t\t\t\t\t{ids['test_target']} = {{\n\t\t\t\t\t\tTestTargetID = {ids['app_target']};\n\t\t\t\t\t}};\n\t\t\t\t}};\n\t\t\t}};\n"
         f"\t\t\tbuildConfigurationList = {ids['project_config_list']};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
         f"\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
         f"\t\t\tmainGroup = {ids['main_group']};\n\t\t\tpackageReferences = (\n\t\t\t\t{ids['package_ref']},\n\t\t\t);\n"
         f"\t\t\tproductRefGroup = {ids['products_group']};\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
         f"\t\t\ttargets = (\n\t\t\t\t{ids['app_target']},\n\t\t\t\t{ids['test_target']},\n\t\t\t);\n\t\t}};\n")
o.append("/* End PBXProject section */\n\n")

o.append("/* Begin PBXResourcesBuildPhase section */\n")
o.append(f"\t\t{ids['app_resources_phase']} = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
         f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
o.append("/* End PBXResourcesBuildPhase section */\n\n")

o.append("/* Begin PBXSourcesBuildPhase section */\n")
files = "".join(f"\t\t\t\t{ids['build_' + f]},\n" for f in app_sources)
o.append(f"\t\t{ids['app_sources_phase']} = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
         f"\t\t\tfiles = (\n{files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
files = "".join(f"\t\t\t\t{ids['build_' + f]},\n" for f in test_sources)
o.append(f"\t\t{ids['test_sources_phase']} = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
         f"\t\t\tfiles = (\n{files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
o.append("/* End PBXSourcesBuildPhase section */\n\n")

o.append("/* Begin PBXTargetDependency section */\n")
o.append(f"\t\t{ids['dependency']} = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {ids['app_target']};\n"
         f"\t\t\ttargetProxy = {ids['proxy']};\n\t\t}};\n")
o.append("/* End PBXTargetDependency section */\n\n")

o.append("/* Begin XCBuildConfiguration section */\n")
for key, name, extra, debug in [
    ("project_debug", "Debug", {}, True), ("project_release", "Release", {}, False),
    ("app_debug", "Debug", app_settings, True), ("app_release", "Release", app_settings, False),
    ("test_debug", "Debug", test_settings, True), ("test_release", "Release", test_settings, False),
]:
    o.append(f"\t\t{ids[key]} = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {settings(extra, debug)};\n"
             f"\t\t\tname = {name};\n\t\t}};\n")
o.append("/* End XCBuildConfiguration section */\n\n")

o.append("/* Begin XCConfigurationList section */\n")
for key, debug, release in [("project_config_list", "project_debug", "project_release"),
                            ("app_config_list", "app_debug", "app_release"),
                            ("test_config_list", "test_debug", "test_release")]:
    o.append(f"\t\t{ids[key]} = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{ids[debug]},\n"
             f"\t\t\t\t{ids[release]},\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
o.append("/* End XCConfigurationList section */\n\n")

if args.package_url:
    o.append("/* Begin XCRemoteSwiftPackageReference section */\n")
    o.append(f"\t\t{ids['package_ref']} = {{\n\t\t\tisa = XCRemoteSwiftPackageReference;\n"
             f"\t\t\trepositoryURL = \"{args.package_url}\";\n\t\t\trequirement = {{\n\t\t\t\tkind = exactVersion;\n"
             f"\t\t\t\tversion = \"{args.package_version}\";\n\t\t\t}};\n\t\t}};\n")
    o.append("/* End XCRemoteSwiftPackageReference section */\n\n")
    package = f"\t\t\tpackage = {ids['package_ref']};\n"
else:
    o.append("/* Begin XCLocalSwiftPackageReference section */\n")
    o.append(f"\t\t{ids['package_ref']} = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = \"{rel}\";\n\t\t}};\n")
    o.append("/* End XCLocalSwiftPackageReference section */\n\n")
    package = ""

o.append("/* Begin XCSwiftPackageProductDependency section */\n")
o.append(f"\t\t{ids['package_dep']} = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n{package}\t\t\tproductName = Kontala;\n\t\t}};\n")
o.append("/* End XCSwiftPackageProductDependency section */\n")

o.append(f"\t}};\n\trootObject = {ids['project']};\n}}\n")

proj = os.path.join(OUT, "KontalaShop.xcodeproj")
os.makedirs(os.path.join(proj, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(proj, "project.pbxproj"), "w") as f:
    f.write("".join(o))

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1640" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{ids['app_target']}" BuildableName = "KontalaShop.app" BlueprintName = "KontalaShop" ReferencedContainer = "container:KontalaShop.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{ids['test_target']}" BuildableName = "KontalaShopUITests.xctest" BlueprintName = "KontalaShopUITests" ReferencedContainer = "container:KontalaShop.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "" selectedLauncherIdentifier = "Xcode.IDEFoundation.Launcher.PosixSpawn" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{ids['app_target']}" BuildableName = "KontalaShop.app" BlueprintName = "KontalaShop" ReferencedContainer = "container:KontalaShop.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
"""
with open(os.path.join(proj, "xcshareddata", "xcschemes", "KontalaShop.xcscheme"), "w") as f:
    f.write(scheme)
print("wrote", proj, "package at", args.package_url and f"{args.package_url} {args.package_version}" or rel)

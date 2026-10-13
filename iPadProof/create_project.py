import json,shlex,os
from pathlib import Path
root=Path(__file__).resolve().parent
command=json.loads((root/'build-engine/compile_commands.json').read_text())[0]['command']
defines=[x[2:] for x in shlex.split(command) if x.startswith('-D')]
def q(s):return json.dumps(str(s))
objects=[]
def add(id,content):objects.append(id+' = { '+content+' };')
for id,path,kind in [('SJ','../Sources/Drift/SyncJournal.swift','sourcecode.swift'),('SN','../Sources/Drift/LocalSync.swift','sourcecode.swift'),('SET','../Sources/Drift/SettingsView.swift','sourcecode.swift'),('AS','../Sources/Drift/AddonStore.swift','sourcecode.swift'),('SA','App/IPadSyncAdapter.swift','sourcecode.swift'),('LS','App/IPadLibraryStore.swift','sourcecode.swift'),('LV','App/IPadLibraryView.swift','sourcecode.swift'),('CACHE','App/IPadCache.swift','sourcecode.swift'),('H','App/IPadHistory.swift','sourcecode.swift'),('POL','../Sources/Drift/SourcePolicy.swift','sourcecode.swift'),('PL','App/IPadPlayback.swift','sourcecode.swift'),('UI','App/IPadLibrary.swift','sourcecode.swift'),('A','../Sources/Drift/Addons.swift','sourcecode.swift'),('SU','../Sources/Drift/Subtitles.swift','sourcecode.swift'),('S','App/ProofApp.swift','sourcecode.swift'),('N','App/NativeMedia.mm','sourcecode.cpp.objcpp'),('V','App/TorrentVideo.swift','sourcecode.swift'),('M','App/TorrentProof.mm','sourcecode.cpp.objcpp'),('L','build-engine/libtorrent-rasterbar.a','archive.ar'),('R','Fixture','folder'),('IC','App/Assets.xcassets','folder.assetcatalog')]:
 add(id,'isa = PBXFileReference; lastKnownFileType = '+kind+'; path = '+q(path)+'; sourceTree = "<group>";')
 add('B'+id,'isa = PBXBuildFile; fileRef = '+id+';')
add('APP','isa = PBXFileReference; explicitFileType = wrapper.application; path = "binge.app"; sourceTree = BUILT_PRODUCTS_DIR;')
add('G','isa = PBXGroup; children = (SJ,SN,SET,AS,SA,LS,LV,CACHE,H,S,V,M,N,PL,UI,A,SU,POL,L,R,IC,APP); sourceTree = "<group>";')
add('SRC','isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (BSJ,BSN,BSET,BAS,BSA,BLS,BLV,BCACHE,BH,BS,BV,BM,BN,BPL,BUI,BA,BSU,BPOL); runOnlyForDeploymentPostprocessing = 0;')
add('FW','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (BL); runOnlyForDeploymentPostprocessing = 0;')
add('RES','isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (BR,BIC); runOnlyForDeploymentPostprocessing = 0;')
settings={
 'PRODUCT_NAME':'binge','MARKETING_VERSION':'0.4.1','CURRENT_PROJECT_VERSION':'10','INFOPLIST_KEY_CFBundleDisplayName':'binge','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','PRODUCT_BUNDLE_IDENTIFIER':'local.binge.torrentproof', 'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','TARGETED_DEVICE_FAMILY':'2',
 'SWIFT_VERSION':'6.0','CLANG_CXX_LANGUAGE_STANDARD':'c++17','CLANG_CXX_LIBRARY':'libc++','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES',
 'GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortraitUpsideDown',
 'INFOPLIST_FILE':'App/Info.plist',
 'SWIFT_OBJC_BRIDGING_HEADER':'$(SRCROOT)/App/Bridge.h','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':os.environ.get('BINGE_DEVELOPMENT_TEAM',''),'ENABLE_USER_SCRIPT_SANDBOXING':'YES',
 'LIBRARY_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/build-engine','$(SRCROOT)/build-media/install/lib'],
 'HEADER_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/vendor/libtorrent-rasterbar-2.0.15/include','$(SRCROOT)/vendor/boost_1_86_0','$(SRCROOT)/build-media/install/include'],
 'GCC_PREPROCESSOR_DEFINITIONS':['$(inherited)']+defines,'OTHER_LDFLAGS':['$(inherited)','-lc++','-framework','SystemConfiguration','-lavformat','-lavcodec','-lswresample','-lavutil','-lz','-liconv'],
}
formatsettings=' '.join(k+' = '+('('+','.join(q(x) for x in v)+')' if isinstance(v,list) else q(v))+';' for k,v in settings.items())
for id,name in [('D','Debug'),('REL','Release')]:
 extra=' SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";'  if name=='Debug' else ' SWIFT_OPTIMIZATION_LEVEL = \"-O\"; GCC_OPTIMIZATION_LEVEL = s; EXCLUDED_SOURCE_FILE_NAMES = (Fixture);'
 add(id,'isa = XCBuildConfiguration; name = '+name+'; buildSettings = { '+formatsettings+extra+' };')
add('CFG','isa = XCConfigurationList; buildConfigurations = (D,REL); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
add('PC','isa = XCBuildConfiguration; name = Debug; buildSettings = {};')
add('PCR','isa = XCBuildConfiguration; name = Release; buildSettings = {};')
add('PCL','isa = XCConfigurationList; buildConfigurations = (PC,PCR); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
add('T','isa = PBXNativeTarget; name = "binge"; productName = "binge"; productReference = APP; productType = "com.apple.product-type.application"; buildConfigurationList = CFG; buildPhases = (SRC,FW,RES); dependencies = (); buildRules = ();')
add('P','isa = PBXProject; attributes = { LastUpgradeCheck = 2700; }; buildConfigurationList = PCL; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = G; projectDirPath = ""; projectRoot = ""; targets = (T);')
p=root/'BingeProof.xcodeproj';p.mkdir(exist_ok=True);(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = P; }\n')

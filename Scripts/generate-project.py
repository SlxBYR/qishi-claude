#!/usr/bin/env python3
"""Generate the optional native WidgetKit Xcode project, without dependencies."""
import hashlib
import json
import pathlib
import plistlib

root = pathlib.Path(__file__).resolve().parent.parent
objects = {}
def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(name, value):
    key = uid(name)
    objects[key] = value
    return key
def ref(path, kind):
    return obj('ref:'+path, dict(isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>'))
sources = sorted(str(p.relative_to(root)) for p in (root/'Sources').glob('*.swift'))
refs = {p: ref(p, 'sourcecode.swift') for p in sources + ['Widget/QishiWidget.swift']}
for path, kind in [('Resources/XcodeInfo.plist','text.plist.xml'),('Widget/Info.plist','text.plist.xml'),('Resources/App.entitlements','text.plist.entitlements'),('Widget/Widget.entitlements','text.plist.entitlements'),('Resources/AppIcon.icns','image.icns')]:
    refs[path] = ref(path,kind)
refs['Resources/Claude'] = ref('Resources/Claude', 'folder')
refs['Resources/Clawd'] = ref('Resources/Clawd', 'folder')
for resource in ['CrossPet','ClawdWeb']:
    refs['Resources/'+resource] = ref('Resources/'+resource, 'folder')
app_product = obj('app-product', dict(isa='PBXFileReference', explicitFileType='wrapper.application', path='栖时·Claude.app', sourceTree='BUILT_PRODUCTS_DIR'))
widget_product = obj('widget-product', dict(isa='PBXFileReference', explicitFileType='wrapper.app-extension', path='QishiWidget.appex', sourceTree='BUILT_PRODUCTS_DIR'))
products = obj('products', dict(isa='PBXGroup', children=[app_product,widget_product], name='Products', sourceTree='<group>'))
group = obj('main-group', dict(isa='PBXGroup', children=list(refs.values())+[products], sourceTree='<group>'))
def source_phase(target, paths):
    files = [obj('build:'+target+':'+p, dict(isa='PBXBuildFile', fileRef=refs[p])) for p in paths]
    return obj(target+'-sources', dict(isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0))
app_sources = source_phase('app', sources)
widget_sources = source_phase('widget', ['Sources/Core.swift','Widget/QishiWidget.swift'])
icon = obj('build-icon',dict(isa='PBXBuildFile',fileRef=refs['Resources/AppIcon.icns']))
resources = obj('app-resources',dict(isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=[icon,obj('build-claude-art',dict(isa='PBXBuildFile',fileRef=refs['Resources/Claude'])),obj('build-clawd-art',dict(isa='PBXBuildFile',fileRef=refs['Resources/Clawd']))],runOnlyForDeploymentPostprocessing=0))
for resource in ['CrossPet','ClawdWeb']:
    objects[resources]['files'].append(obj('build-'+resource,dict(isa='PBXBuildFile',fileRef=refs['Resources/'+resource])))
embed_file = obj('embed-widget-file',dict(isa='PBXBuildFile',fileRef=widget_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy','CodeSignOnCopy']}))
embed = obj('embed-widget',dict(isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embed_file],name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0))
proxy = obj('widget-proxy',dict(isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=uid('widget-target'),remoteInfo='QishiWidget'))
dependency = obj('widget-dependency',dict(isa='PBXTargetDependency',target=uid('widget-target'),targetProxy=proxy))
common = dict(SDKROOT='macosx',MACOSX_DEPLOYMENT_TARGET='27.0',SWIFT_VERSION='5.0',CLANG_ENABLE_MODULES='YES',CODE_SIGN_STYLE='Automatic',DEVELOPMENT_TEAM='',QISHI_APP_GROUP='$(DEVELOPMENT_TEAM).local.qishi.claude.shared',ENABLE_HARDENED_RUNTIME='YES')
def configs(name, settings):
    ids=[]
    for variant in ['Debug','Release']:
        values = dict(settings)
        values['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if variant=='Debug' else '-O'
        ids.append(obj(name+'-'+variant,dict(isa='XCBuildConfiguration',name=variant,buildSettings=values)))
    return obj(name+'-configs',dict(isa='XCConfigurationList',buildConfigurations=ids,defaultConfigurationIsVisible=0,defaultConfigurationName='Release'))
project_configs=configs('project',common)
app_configs=configs('app',dict(PRODUCT_NAME='栖时·Claude',EXECUTABLE_NAME='Qishi',PRODUCT_BUNDLE_IDENTIFIER='local.qishi.claude-companion',INFOPLIST_FILE='Resources/XcodeInfo.plist',CODE_SIGN_ENTITLEMENTS='Resources/App.entitlements',GENERATE_INFOPLIST_FILE='NO',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks']))
widget_configs=configs('widget',dict(PRODUCT_NAME='QishiWidget',PRODUCT_BUNDLE_IDENTIFIER='local.qishi.claude-companion.widget',INFOPLIST_FILE='Widget/Info.plist',CODE_SIGN_ENTITLEMENTS='Widget/Widget.entitlements',GENERATE_INFOPLIST_FILE='NO',APPLICATION_EXTENSION_API_ONLY='YES',SKIP_INSTALL='YES',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks','@executable_path/../../../../Frameworks']))
obj('app-target',dict(isa='PBXNativeTarget',buildConfigurationList=app_configs,buildPhases=[app_sources,resources,embed],buildRules=[],dependencies=[dependency],name='Qishi',productName='栖时',productReference=app_product,productType='com.apple.product-type.application'))
obj('widget-target',dict(isa='PBXNativeTarget',buildConfigurationList=widget_configs,buildPhases=[widget_sources],buildRules=[],dependencies=[],name='QishiWidget',productName='QishiWidget',productReference=widget_product,productType='com.apple.product-type.app-extension'))
obj('project',dict(isa='PBXProject',attributes={'LastUpgradeCheck':'2700','TargetAttributes':{uid('app-target'):{'SystemCapabilities':{'com.apple.ApplicationGroups.Mac':{'enabled':1},'com.apple.Sandbox':{'enabled':1}}},uid('widget-target'):{'SystemCapabilities':{'com.apple.ApplicationGroups.Mac':{'enabled':1},'com.apple.Sandbox':{'enabled':1}}}}},buildConfigurationList=project_configs,compatibilityVersion='Xcode 14.0',developmentRegion='zh-Hans',hasScannedForEncodings=0,knownRegions=['zh-Hans','en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[uid('app-target'),uid('widget-target')]))
def encode(value, indent=0):
    if isinstance(value,dict):
        return '{\n'+''.join('\t'*(indent+1)+json.dumps(str(k),ensure_ascii=False)+' = '+encode(v,indent+1)+';\n' for k,v in value.items())+'\t'*indent+'}'
    if isinstance(value,list):
        return '('+', '.join(encode(v,indent) for v in value)+')'
    if isinstance(value,int):return str(value)
    return json.dumps(value,ensure_ascii=False)
project=root/'Qishi.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(dict(archiveVersion=1,classes={},objectVersion=56,objects=objects,rootObject=uid('project')))+'\n')
info=plistlib.loads((root/'Resources/Info.plist').read_bytes())
info['CFBundleIdentifier']='$(PRODUCT_BUNDLE_IDENTIFIER)'
info['QishiAppGroup']='$(QISHI_APP_GROUP)'
(root/'Resources/XcodeInfo.plist').write_bytes(plistlib.dumps(info))
for path,network in [('Resources/App.entitlements',True),('Widget/Widget.entitlements',False)]:
    entitlements={'com.apple.security.app-sandbox':True,'com.apple.security.application-groups':['$(QISHI_APP_GROUP)']}
    if network:
        entitlements['com.apple.security.network.client']=True
        entitlements['com.apple.security.app-sandbox']=False # User-selected Claude hook integration needs local settings access.
    (root/path).write_bytes(plistlib.dumps(entitlements))
scheme=project/'xcshareddata/xcschemes'
scheme.mkdir(parents=True,exist_ok=True)
(scheme/'Qishi.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('app-target')}" BuildableName="栖时·Claude.app" BlueprintName="Qishi" ReferencedContainer="container:Qishi.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('app-target')}" BuildableName="栖时·Claude.app" BlueprintName="Qishi" ReferencedContainer="container:Qishi.xcodeproj"/></BuildableProductRunnable></LaunchAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>
''')
print(project)

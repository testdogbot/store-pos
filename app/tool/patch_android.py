"""flutter create 生成 android/ 之后打补丁：权限、应用名、url_launcher 查询、固定签名。"""
import pathlib, re, sys

m = pathlib.Path('android/app/src/main/AndroidManifest.xml')
s = m.read_text()
if 'android.permission.CAMERA' not in s:
    s = s.replace(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <uses-permission android:name="android.permission.INTERNET"/>\n'
        '    <uses-permission android:name="android.permission.CAMERA"/>', 1)
s = s.replace('android:label="store_pos"', 'android:label="小店收银"')
browse = ('        <intent>\n            <action android:name="android.intent.action.VIEW"/>\n'
          '            <data android:scheme="https"/>\n        </intent>\n')
if '<queries>' in s:
    s = s.replace('<queries>\n', '<queries>\n' + browse, 1)
else:
    s = s.replace('</manifest>', '    <queries>\n' + browse + '    </queries>\n</manifest>')
m.write_text(s)

# 固定签名：每次构建都用同一个证书，新版才能直接覆盖安装旧版
kts = pathlib.Path('android/app/build.gradle.kts')
groovy = pathlib.Path('android/app/build.gradle')
if kts.exists():
    g = kts.read_text()
    block = '''    signingConfigs {
        create("release") {
            storeFile = file("../../android-signing/release.p12")
            storePassword = "storepos2026"
            keyAlias = "storepos"
            keyPassword = "storepos2026"
            storeType = "PKCS12"
        }
    }

    buildTypes {'''
    g = g.replace('    buildTypes {', block, 1)
    g, n = re.subn(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
                   'signingConfig = signingConfigs.getByName("release")', g)
    kts.write_text(g)
else:
    g = groovy.read_text()
    block = '''    signingConfigs {
        release {
            storeFile file("../../android-signing/release.p12")
            storePassword "storepos2026"
            keyAlias "storepos"
            keyPassword "storepos2026"
            storeType "PKCS12"
        }
    }

    buildTypes {'''
    g = g.replace('    buildTypes {', block, 1)
    g, n = re.subn(r'signingConfig\s*=?\s*signingConfigs\.debug', 'signingConfig signingConfigs.release', g)
    groovy.write_text(g)
if n != 1:
    sys.exit('签名配置替换失败，请检查 build.gradle 模板')
print(m.read_text())
print('signing patched')

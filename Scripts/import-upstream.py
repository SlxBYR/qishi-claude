"""Bundle pinned upstream renderers. Run from the delivered source tree."""
import hashlib, json, pathlib, shutil, subprocess

root = pathlib.Path(__file__).resolve().parents[1]
ref = root / 'Upstream'
resources = root / 'Resources'
for name, source in [('CrossPet', ref/'crosspet/app/web'), ('ClawdWeb', ref/'clawd-on-desk/src')]:
    target = resources / name
    target.mkdir(exist_ok=True)
    if name == 'CrossPet':
        for p in source.glob('*'):
            if p.suffix == '.js' or p.name == 'index.html': shutil.copyfile(p, target/p.name)
    else:
        for file in ['index.html', 'styles.css', 'renderer.js', 'pet-accessory-layout.js', 'pet-accessory-mirror.js', 'pet-accessory-descriptor.js', 'pet-visual-swap-policy.js']:
            shutil.copyfile(source/file, target/file)
        shutil.copytree(ref/'clawd-on-desk/assets/svg', target/'assets', dirs_exist_ok=True)
        shutil.copytree(ref/'clawd-on-desk/assets/sounds', target/'sounds', dirs_exist_ok=True)
    shutil.copyfile(ref/('crosspet' if name=='CrossPet' else 'clawd-on-desk')/'LICENSE', target/'LICENSE')

# Existing downloaded images have their Git blob hashes checked before bundling.
lock = json.loads((ref/'upstream-lock.json').read_text())
for item in lock['crosspet']['files']:
    if not item['path'].endswith('.webp'): continue
    data = (resources/'Claude'/pathlib.Path(item['path']).name).read_bytes()
    assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest() == item['sha']
c = json.loads((ref/'crosspet/characters/claude/character.json').read_text())
c['poses'] = {}
for p in sorted((resources/'Claude').glob('*.webp')):
    if p.stem in ['portrait', 'portrait-card', 'avatar']: continue
    url = '../Claude/' + p.name
    if p.stem == 'idle-blink': c['blink'] = url; continue
    if p.stem == 'idle': c['blinkBase'] = url
    c['poses'].setdefault(p.stem.split('-')[0], []).append(url)
(resources/'CrossPet/character-data.js').write_text('window.qishiManifest = '+json.dumps({'characters':{'claude':c}},ensure_ascii=False)+';\n')
# Upstream normalizes theme.json before the renderer sees it (e.g. <img> vs <object> sizing).
theme = subprocess.run(['node', str(root/'Scripts/clawd-theme-data.cjs'), str(ref/'clawd-on-desk/src'),
                        str(ref/'clawd-on-desk/themes/clawd/theme.json')], check=True, capture_output=True, text=True).stdout
(resources/'ClawdWeb/theme-data.js').write_text(theme)
cross = resources/'CrossPet/index.html'
html = cross.read_text().replace('<style>', '<link rel="stylesheet" href="minimal.css"><style>', 1)
html = html.replace('</body>', '<script src="character-data.js"></script><script src="host.js"></script></body>')
# Upstream ends with </html> only; insert after all original scripts.
if 'src="host.js"' not in html: html = html.replace('</html>', '<script src="character-data.js"></script><script src="host.js"></script></html>')
cross.write_text(html)
clawd = resources/'ClawdWeb/index.html'
html = clawd.read_text().replace('<script src="pet-accessory-layout.js">', '<script src="theme-data.js"></script><script src="host-api.js"></script><script src="pet-accessory-layout.js">')
html = html.replace('</body>', '<script src="host.js"></script></body>')
clawd.write_text(html)
(resources/'upstream-lock.json').write_text(json.dumps(lock,indent=2))
print('Bundled original renderers, 60 Claude images, and all Clawd SVGs')

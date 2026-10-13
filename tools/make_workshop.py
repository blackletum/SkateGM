"""The Workshop copy of the add-on: release/workshop/skategm (staged from HEAD
through make_public's filters and leak check) packed into
release/skategm_workshop_<version>.gma with GMod's gmad, plus icon.jpg and
description.txt for the Workshop page. Publishing is gmpublish's job, run by
hand (it needs your Steam login): the commands are printed at the end.

    python tools/make_workshop.py [GarrysMod folder]
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / 'exporter'))
import make_public

ADDON = 'addon/skategm/'
OUT = ROOT / 'release'
STAGE = OUT / 'workshop' / 'skategm'
TYPES = {'gamemode', 'map', 'weapon', 'vehicle', 'npc', 'entity', 'tool', 'effects', 'model', 'servercontent'}
TAGS = {'fun', 'roleplay', 'scenic', 'movie', 'realism', 'cartoon', 'water', 'comic', 'build'}
ICON = 512


def gmod_dir(arg):
    if arg:
        return Path(arg)
    from mapgen.sourcetools import find_gmod
    found = find_gmod()
    if not found:
        sys.exit("Garry's Mod not found: pass its folder")
    return Path(found)


def stage(files):
    if STAGE.exists():
        shutil.rmtree(STAGE)
    count = 0
    for path, (data, _) in sorted(files.items()):
        if not path.startswith(ADDON):
            continue
        out = STAGE / path[len(ADDON):]
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
        count += 1
    if not count:
        sys.exit('no add-on files at HEAD')
    meta = json.loads((STAGE / 'addon.json').read_text(encoding='utf-8'))
    if meta.get('type') not in TYPES:
        sys.exit(f"addon.json type must be one of {sorted(TYPES)}")
    bad = [t for t in meta.get('tags', []) if t not in TAGS]
    if bad or len(meta.get('tags', [])) > 2:
        sys.exit(f'addon.json tags: at most 2 of {sorted(TAGS)} (not {bad})')
    return count


def icon(out):
    from PIL import Image
    art = ROOT / 'docs' / 'workshop_icon.png'
    if art.exists():
        im = Image.open(art).convert('RGB')
        side = min(im.size)
        left, top = (im.width - side) // 2, (im.height - side) // 2
        im.crop((left, top, left + side, top + side)).resize((ICON, ICON), Image.LANCZOS).save(out, 'JPEG', quality=92)
        return
    logo = Image.open(ROOT / 'addon' / 'skategm' / 'materials' / 'skategm' / 'logo.png').convert('RGBA')
    canvas = Image.new('RGB', (ICON, ICON), (18, 20, 24))
    scale = (ICON * 0.86) / logo.width
    logo = logo.resize((round(logo.width * scale), round(logo.height * scale)), Image.LANCZOS)
    canvas.paste(logo, ((ICON - logo.width) // 2, (ICON - logo.height) // 2), logo)
    canvas.save(out, 'JPEG', quality=92)


def main():
    gmod = gmod_dir(sys.argv[1] if len(sys.argv) > 1 else None)
    gmad = gmod / 'bin' / 'gmad.exe'
    if not gmad.is_file():
        sys.exit(f'{gmad} not found')
    version = make_public.version()
    files, problems = make_public.collect()
    if problems:
        sys.exit('not packing, these look private:\n' + '\n'.join(problems))
    count = stage(files)
    gma = OUT / f'skategm_workshop_{version}.gma'
    gma.unlink(missing_ok=True)
    result = subprocess.run([str(gmad), 'create', '-folder', str(STAGE), '-out', str(gma), '-warninvalid'],
                            capture_output=True, text=True)
    if result.returncode != 0 or not gma.is_file():
        sys.exit('gmad failed:\n' + result.stdout + result.stderr)
    ignored = [line for line in result.stdout.splitlines() if 'not allowed' in line.lower() or 'ignored' in line.lower()]
    icon(OUT / 'workshop' / 'icon.jpg')
    shutil.copy2(ROOT / 'docs' / 'WORKSHOP.txt', OUT / 'workshop' / 'description.txt')
    print(f'{count} files -> {gma} ({gma.stat().st_size / 2**20:.1f} MB)')
    for line in ignored:
        print('  ' + line.strip())
    gmpublish = gmod / 'bin' / 'gmpublish.exe'
    print('\nFirst upload (Steam running, logged in; PowerShell):')
    print(f'  & "{gmpublish}" create -addon "{gma}" -icon "{OUT / "workshop" / "icon.jpg"}"')
    print('Updates after that (the id the first upload printed):')
    print(f'  & "{gmpublish}" update -addon "{gma}" -id <id> -changes "SkateGM {version}"')
    print(f'Then paste {OUT / "workshop" / "description.txt"} into the Workshop page, and put the id in')
    print('installer/setup_skategm.py WORKSHOP_ID.')


if __name__ == '__main__':
    main()

import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_public

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, 'gm_skategm', 'prebuilt', 'gmcl_skategm_win64.dll')
ADDON = os.path.join(ROOT, 'addon', 'skategm')


def version():
    with open(os.path.join(ROOT, 'VERSION'), encoding='utf-8') as f:
        return f.read().strip()


def main():
    v = sys.argv[1] if len(sys.argv) > 1 else version()
    out_dir = os.path.join(ROOT, 'release')
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, 'skategm_%s.zip' % v)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(DLL, 'gmcl_skategm_win64.dll')
        prebuilt = os.path.dirname(DLL)
        for name in ['skategm_sdl2.dll', 'skategm_gamecontrollerdb.txt']:
            z.write(os.path.join(prebuilt, name), name)
        for name in ['SDL2-LICENSE.txt', 'SDL2-README.txt', 'SDL_GameControllerDB-LICENSE.txt']:
            z.write(os.path.join(prebuilt, name), 'licenses/' + name)
        files, problems = make_public.collect()
        if problems:
            sys.exit('not releasing, these look private: ' + '; '.join(problems))
        singles = {'LICENSE', 'LICENSE-THIRD-PARTY.md', 'engine/LICENSE', 'engine/NOTICE-mashup', 'engine/README.md', 'README.md'}
        for path in sorted(files):
            if path.startswith('exporter/') and os.path.basename(path) != 'import_upstream.py':
                z.writestr(path, files[path][0])
            elif path in singles:
                z.writestr(path, files[path][0])
            elif path.startswith('addon/skategm/'):
                z.writestr(path[len('addon/'):], files[path][0])
    print(out)


if __name__ == '__main__':
    main()

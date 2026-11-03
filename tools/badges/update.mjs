import { makeBadge } from 'badge-maker';
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname).replace(/^\/([A-Za-z]:)/, '$1');
const root = path.resolve(here, '..', '..');
const dist = path.join(root, 'dist');
const badges = path.join(root, 'badges');

const installers = fs
  .readdirSync(dist)
  .filter((name) => /^NovaSSH-\d+\.\d+\.\d+-windows-x64-installer\.exe$/.test(name))
  .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
if (installers.length === 0) {
  throw new Error('No NovaSSH-*-windows-x64-installer.exe in dist; run package-windows first');
}
const installer = installers[installers.length - 1];
const version = installer.match(/^NovaSSH-(\d+\.\d+\.\d+)-/)[1];
const sizeMb = (fs.statSync(path.join(dist, installer)).size / 1024 / 1024).toFixed(1);

fs.mkdirSync(badges, { recursive: true });
const write = (name, svg) => fs.writeFileSync(path.join(badges, name), svg, 'utf8');

write(
  'downloads.svg',
  makeBadge({
    label: 'Downloads',
    message: `${sizeMb} MB`,
    color: '#44cc11',
    style: 'flat',
  }),
);
write(
  'platform.svg',
  makeBadge({
    label: 'platform',
    message: 'Windows | Android',
    color: '#6f42c1',
    style: 'flat',
  }),
);

console.log(`badges updated for ${version}: Downloads ${sizeMb} MB`);

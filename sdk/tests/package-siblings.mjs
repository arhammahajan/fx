// sdk/scripts/package-libfx.mjs writes libfx and the packages that ship beside
// it into one directory: `<dist>/libfx`, `<dist>/libfx-<platform>` and
// `<dist>/libfx-term`. `npm pack` names their tarballs `libfx-<version>.tgz`,
// `libfx-<platform>-<version>.tgz` and `libfx-term-<version>.tgz`. Given
// libfx's directory or tarball, these return the one beside it, or null.
import { existsSync } from "node:fs";
import { basename, dirname, join } from "node:path";

export const nativePlatform = `${process.platform}-${process.arch}`;

/** `@libfx/<name>`, such as `term` or `linux-x64`. */
export function packageBeside(libfx, name) {
  if (!libfx.endsWith(".tgz")) {
    const dir = join(dirname(libfx), `libfx-${name}`);
    return existsSync(join(dir, "package.json")) ? dir : null;
  }
  const version = /^libfx-(.+)\.tgz$/.exec(basename(libfx))?.[1];
  const tarball = version && join(dirname(libfx), `libfx-${name}-${version}.tgz`);
  return tarball && existsSync(tarball) ? tarball : null;
}

/** This machine's @libfx/<platform>, the package with its native addon. */
export const nativePackageBeside = (libfx) => packageBeside(libfx, nativePlatform);

/** @libfx/term. */
export const termPackageBeside = (libfx) => packageBeside(libfx, "term");

#!/usr/bin/env python3
"""Standalone helper to download Rust crates and bundle them into a tarball.

Reads one or more Cargo.lock files, downloads the crates listed there,
verifies their checksums and repacks them into a single tarball.
Reuses fetching and verification logic from ``pycargoebuild``.
"""

from __future__ import annotations

import argparse
import datetime as dt
import io
import json
import logging
import lzma  # TODO: maybe support zstd, this is available in python 3.14
import os
import sys
import tarfile
import tempfile
from collections.abc import Iterable, Iterator
from contextlib import nullcontext
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, NamedTuple, Protocol


if sys.version_info >= (3, 11):  # noqa: UP036 # better be safe than sorry
    import tomllib
else:
    try:
        import tomli as tomllib  # pip install tomli for older versions
    except ImportError as e:
        raise RuntimeError(
            "TOML parsing requires Python >=3.11 (with tomllib) or the 'tomli' package."
        ) from e

import asyncio

import aiohttp
import uvloop
from aiolimiter import AsyncLimiter
from pycargoebuild.cargo import (  # type: ignore[import-untyped]
    Crate,
    FileCrate,
    WorkspaceCargoTomlError,
    get_crates,
    get_package_metadata,
)
from pycargoebuild.fetch import (  # type: ignore[import-untyped]
    fetch_crates_using_aria2,
    fetch_crates_using_wget,
    verify_crates,
)


uvloop.install()

logger = logging.getLogger(__name__)

FETCHERS = ("aiohttp", "aria2", "wget")


class WorkspaceData(NamedTuple):
    crates: frozenset[Crate]
    workspace_metadata: dict[str, Any]


def iter_self_and_parents(directory: Path) -> Iterator[Path]:
    """Yield directory, then its parents up to the filesystem root"""
    base = directory.resolve()
    yield base
    yield from base.parents


def get_workspace_root(directory: Path) -> WorkspaceData:
    last_error: Exception | None = None

    for base in iter_self_and_parents(directory):
        try:
            lock_path = base / "Cargo.lock"
            with lock_path.open("rb") as cargo_lock:
                workspace_toml: dict[str, Any] = {}
                cargo_toml_path = base / "Cargo.toml"
                if cargo_toml_path.is_file():
                    with cargo_toml_path.open("rb") as cargo_toml:
                        workspace: dict[str, Any] = tomllib.load(cargo_toml).get("workspace", {})
                        workspace_toml = workspace.get("package", {}) or {}

                return WorkspaceData(
                    crates=frozenset(get_crates(cargo_lock)), workspace_metadata=workspace_toml
                )
        except FileNotFoundError as e:
            last_error = e
            continue

    raise RuntimeError("Cargo.lock not found in the given directory or any parent") from last_error


class Fetcher(Protocol):
    def __call__(self, crates: Iterable[Crate], *, distdir: Path) -> None: ...


def _safe_member_name(info: tarfile.TarInfo, crate_dir: PurePosixPath, prefix: str) -> str:
    # TarInfo.name is POSIX-style; normalize via PurePosixPath and ensure crate-rooted.
    original_path = PurePosixPath(info.name)
    if not original_path.is_relative_to(crate_dir):
        raise ValueError(f"Refusing to pack member outside crate dir: {original_path!s}")

    return f"{prefix}/{original_path}"


def _add_crate_to_tar(
    crate: FileCrate,
    *,
    distdir: Path,
    tar_out: tarfile.TarFile,
    prefix: str,
) -> None:
    """Read one crate .tar.gz from distdir and append its contents to tar_out under prefix."""
    with tarfile.open(distdir / crate.filename, "r:gz") as tar_in:
        crate_dir = crate.get_package_directory(distdir)

        for info in tar_in:
            new_name = _safe_member_name(info, PurePosixPath(crate_dir), prefix)

            if info.isdir() or info.issym() or info.islnk():
                # for non-regulars, just forward metadata
                info.name = new_name  # Avoid the deepcopy that .replace introduces
                tar_out.addfile(info)
                continue

            if not info.isreg():
                # Skip unusual filetypes (FIFOs, devs, etc...)
                logging.debug("Skipping non-regular member: %s", info.name)
                continue

            with nullcontext(tar_in.extractfile(info)) as member:
                if member is None:
                    raise RuntimeError(f"Failed to extract {info.name}")

                info.name = new_name
                tar_out.addfile(info, member)

    # Write the cargo checksum alongside the package contents
    checksum_data = json.dumps({"package": crate.checksum, "files": {}})
    checksum_info = tarfile.TarInfo(f"{prefix}/{crate_dir}/.cargo-checksum.json")
    checksum_info.size = len(checksum_data)
    checksum_info.mode = 0o644
    tar_out.addfile(checksum_info, io.BytesIO(checksum_data.encode()))


class DownloadError(Exception):
    def __init__(self, crate: FileCrate, cause: BaseException) -> None:
        super().__init__(f"failed: {crate.filename} ({crate.download_url}): {cause!r}")
        self.crate: FileCrate = crate
        self.__cause__ = cause


def fetch_crates_using_aiohttp(crates: Iterable[Crate], *, distdir: Path) -> None:
    """
    Portable async fetcher using aiohttp + aiolimiter, optimized for CI.
    - Uses uvloop when available.
    - Streams to *.part and renames atomically.
    - Skips files already present.
    - Retries 429/5xx with exponential backoff.
    Environment knobs:
      VENDOR_CRATES_CONCURRENCY (default: 4*CPU, capped at 32, min 4)
      VENDOR_CRATES_RPS         (default: concurrency)
      VENDOR_CRATES_RETRIES     (default: 4)
    """
    # Only download file-backed crates; others are handled elsewhere
    if not (file_crates := [crate for crate in crates if isinstance(crate, FileCrate)]):
        return

    default_concurrency = min(32, max(4, (os.cpu_count() or 4) * 4))
    concurrency = int(os.getenv("VENDOR_CRATES_CONCURRENCY", str(default_concurrency)))
    rate_per_sec = int(os.getenv("VENDOR_CRATES_RPS", str(concurrency)))
    retries = int(os.getenv("VENDOR_CRATES_RETRIES", "4"))

    async def _run() -> None:
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=300)
        # We rely on our own semaphore/limiter, so we do not cap connector directly
        connector = aiohttp.TCPConnector(limit=0, ttl_dns_cache=300)

        headers = {
            "User-Agent": (
                f"crates_vendoring/1.0 (+github-actions={os.getenv('GITHUB_ACTIONS', '')}) "
                f"Python/{sys.version_info[0]}.{sys.version_info[1]}"
            )
        }

        semaphore = asyncio.Semaphore(concurrency)
        limiter = AsyncLimiter(rate_per_sec, time_period=1)

        async with aiohttp.ClientSession(
            connector=connector,
            timeout=timeout,
            headers=headers,
            trust_env=True,  # respect proxy/CA settings in Actions
            auto_decompress=False,  # stream raw bytes for .crate/.tar.gz
        ) as session:

            async def download_crate(crate: FileCrate) -> None:
                # Ensure we never write outside distdir and keep exact filename
                filename = crate.filename
                if Path(filename).is_absolute() or ("/" in filename) or ("\\" in filename):
                    raise ValueError(f"Unsafe crate filename: {filename!r}")

                destination = distdir / filename
                if destination.exists() and destination.stat().st_size > 0:
                    logger.info("Skipping existing crate %s (already present)", filename)
                    return  # Already present, verification will run later

                url = crate.download_url
                temp_file = destination.with_suffix(destination.suffix + ".part")
                backoff = 0.5

                for attempt in range(1, retries + 1):
                    logger.info("Starting download of %s (attempt %d)", filename, attempt)
                    try:
                        async with (
                            semaphore,
                            limiter,
                            session.get(url, allow_redirects=True) as response,
                        ):
                            # Retry on common transient statuses
                            if response.status in (429, 500, 502, 503, 504):
                                raise aiohttp.ClientResponseError(
                                    response.request_info,
                                    response.history,
                                    status=response.status,
                                    message="retryable",
                                )

                            response.raise_for_status()
                            temp_file.parent.mkdir(parents=True, exist_ok=True)

                            # Stream to disk
                            with temp_file.open("wb") as output_file:
                                async for chunk in response.content.iter_chunked(1 << 16):
                                    if chunk:
                                        output_file.write(chunk)

                            os.replace(
                                temp_file, destination
                            )  # Atomically replace on POSIX/windows
                            logger.info("Finished download of %s (attempt %d)", filename, attempt)
                            return

                    except asyncio.CancelledError:
                        # Clean partials and retry if we have attempts left
                        try:
                            temp_file.unlink(missing_ok=True)
                        finally:
                            raise

                    except Exception as e:
                        try:
                            temp_file.unlink(missing_ok=True)
                        except OSError:
                            pass

                        if attempt == retries:
                            raise DownloadError(crate, e) from e

                        await asyncio.sleep(backoff)
                        backoff *= 2

            try:
                async with asyncio.TaskGroup() as tg:
                    for crate in file_crates:
                        tg.create_task(download_crate(crate))
            except* DownloadError as eg:
                only_downloads, rest = eg.split(DownloadError)

                if only_downloads is not None:
                    failed = [
                        ex.crate.filename
                        for ex in only_downloads.exceptions
                        if isinstance(ex, DownloadError)
                    ]
                    raise RuntimeError(f"Some downloads failed: {failed}") from only_downloads

                if rest is not None:
                    raise rest from eg

    asyncio.run(_run())


FETCHER_FUNCS: tuple[Fetcher, ...] = (
    fetch_crates_using_aiohttp,
    fetch_crates_using_aria2,
    fetch_crates_using_wget,
)


def _try_fetcher(func: Fetcher, crates: Iterable[Crate], *, distdir: Path) -> bool:
    try:
        func(crates, distdir=distdir)
    except FileNotFoundError:
        return False
    return True


def fetch_crates(crates: Iterable[Crate], *, distdir: Path) -> None:
    """Try aria2, then wget. Raise if neither is available."""
    for fetcher in FETCHER_FUNCS:
        if _try_fetcher(fetcher, crates, distdir=distdir):
            return

    raise RuntimeError(f"No supported fetcher found (tried {', '.join(FETCHERS)})")


# TODO: switching to zstd might be beneficial here, we can utilize uv to install python 3.14, which
# has zstd support in the stdlib. for a massive amount of crates (800+), xz takes obscenely long
# which makes something like zstd -13 or -19 (maybe) much more appealing.
def repack_crates(crates: set[Crate], *, distdir: Path, tarball: Path, prefix: str) -> None:
    """Repack fetched crates into a tarball."""
    # discover current umask without changing it
    current_umask = os.umask(0)
    os.umask(current_umask)

    xz_preset = 9 | lzma.PRESET_EXTREME
    total_crates = len(crates)

    with tempfile.NamedTemporaryFile(mode="wb", dir=distdir, delete=False) as tmp_file:
        try:
            # Wrap the tempfile in an XZ stream so that we can pass LZMA options explicitly
            with lzma.open(
                tmp_file, mode="wb", format=lzma.FORMAT_XZ, preset=xz_preset, check=lzma.CHECK_CRC64
            ) as xz_stream:
                with tarfile.open(
                    fileobj=xz_stream,
                    mode="w",  # Write uncompressed tar into the xz stream
                    format=tarfile.GNU_FORMAT,
                    encoding="UTF-8",
                ) as tar_out:
                    # Set file mode to default "rw-rw-rw-" (0666), masked by the current umask.
                    # This ensures the tarball ends up with normal user file permissions
                    # (e.g. typically 0644 when umask=0022).
                    os.fchmod(tmp_file.fileno(), 0o666 & ~current_umask)

                    start_time = dt.datetime.now(dt.UTC)
                    next_ping = start_time + dt.timedelta(seconds=10)

                    logging.info("Repacking %d crates", total_crates)

                    for idx, crate in enumerate(
                        sorted(crates, key=lambda crate: crate.filename), 1
                    ):
                        current_time = dt.datetime.now(dt.UTC)
                        if current_time >= next_ping:
                            logging.info("Processed %d/%d crates", idx - 1, total_crates)
                            next_ping = current_time + dt.timedelta(seconds=10)

                        if not isinstance(crate, FileCrate):
                            continue  # future-proof: only file-backed crates are packed

                        _add_crate_to_tar(crate, distdir=distdir, tar_out=tar_out, prefix=prefix)

                        end_time = dt.datetime.now(dt.UTC)
                        logging.debug("Time elapsed during repacking: %s", end_time - start_time)
        except BaseException:
            Path(tmp_file.name).unlink(missing_ok=True)
            raise

    Path(tmp_file.name).rename(tarball)

    end_time = dt.datetime.now(dt.UTC)
    logging.info(
        "Repacked %d crates into %s in %s",
        total_crates,
        tarball,
        end_time - start_time,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download crates from Cargo.lock and bundle them into a tarball",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "directory",
        nargs="+",
        type=Path,
        help="Directories containing Cargo.lock",
    )
    parser.add_argument(
        "-d",
        "--distdir",
        type=Path,
        default=Path("distdir"),
        help="Directory to store downloaded crates",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="{distdir}/{name}-{version}-crates.tar.xz",
        help="Path to write the crate tarball; available replacements: {name}, {version}, {distdir}",  # noqa: E501
    )
    parser.add_argument(
        "--prefix",
        default="cargo_home/gentoo",
        help="Prefix for paths stored inside the tarball",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Shorthand for --log-level=DEBUG"
    )
    parser.add_argument(
        "--log-level",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        default=None,
        help="Explicit logging level (overrides CI auto-detection and -v)",
    )

    return parser


@dataclass
class Args:
    directory: list[Path]
    distdir: Path
    output: str
    prefix: str
    verbose: bool
    log_level: str | None = None


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    raw_args = parser.parse_args()
    args = Args(**vars(raw_args))

    # Determine log level: explicit flag -> -v -> LOG_LEVEL env -> CI auto -> WARNING
    env_level = os.getenv("LOG_LEVEL")
    if args.log_level:
        level_name = args.log_level
    elif args.verbose:
        level_name = "DEBUG"
    elif env_level:
        level_name = env_level
    # We only support GITHUB_ACTIONS detection for now since it's what we use
    elif os.getenv("GITHUB_ACTIONS"):
        level_name = "INFO"
    else:
        level_name = "WARNING"

    try:
        level = getattr(logging, level_name.upper())
    except Exception:
        level = logging.WARNING

    log_format = "%(asctime)s %(levelname)s %(name)s: %(message)s"
    datefmt = "%Y-%m-%dT%H:%M:%S%z"
    logging.basicConfig(level=level, format=log_format, datefmt=datefmt)

    crates: set[Crate] = set()
    pkg_metadata = None

    for directory in args.directory:
        workspace = get_workspace_root(directory)
        crates.update(workspace.crates)

        try:
            with (directory / "Cargo.toml").open("rb") as file:
                metadata = get_package_metadata(file, workspace.workspace_metadata)
        except FileNotFoundError:
            logging.error("'Cargo.toml' not found in %r", str(directory))
            return 1
        except WorkspaceCargoTomlError as e:
            logging.error("The specified directory is a workspace root: %r", str(directory))
            logging.info("Please run crate_tarball in one of its members: %s", " ".join(e.members))
            return 1

        if pkg_metadata is None:
            pkg_metadata = metadata

    if pkg_metadata is None:
        logging.error("No package metadata discovered")
        return 1

    args.distdir.mkdir(parents=True, exist_ok=True)
    tarball_path = Path(
        args.output.format(
            name=pkg_metadata.name, version=pkg_metadata.version, distdir=args.distdir
        )
    )

    fetch_crates(crates, distdir=args.distdir)
    verify_crates(crates, distdir=args.distdir)
    repack_crates(crates, distdir=args.distdir, tarball=tarball_path, prefix=args.prefix)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

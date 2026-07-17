"""Atheris-style fuzz harness body for pyshp's pure-Python shapefile reader.

The *fuzzed code* is `shapefile.Reader` parsing an attacker-controlled `.shp`
byte stream. We feed the raw input as the `.shp` file object (no `.shx`/`.dbf`
required — the reader parses geometry straight from `.shp`) and then walk every
shape, which drives the record/geometry decoders end to end.

This module is invoked from the native libFuzzer driver (`fuzz_shp_driver.c`),
which embeds CPython and calls `TestOneInput(data: bytes)` once per input. It is
deliberately written so the SAME function also runs under Atheris
(`python3 fuzz_shapefile.py`) for local experimentation.

We swallow the *expected* parse errors pyshp raises on malformed input
(`ShapefileException`, plus the usual value/struct/decoding errors a bytes
parser throws) — those are normal "rejected the bad file" outcomes, not defects.
Anything else (an unexpected exception class, or a native crash inside the
interpreter / a C accelerator) escapes and is reported as a finding.
"""

import io
import struct

import shapefile


def TestOneInput(data: bytes) -> None:
    if not data:
        return
    try:
        # Parse geometry straight from the .shp stream. BytesIO gives the
        # seekable binary stream the Reader expects, with no temp files.
        reader = shapefile.Reader(shp=io.BytesIO(data))
        # Touch the headers, then force a full parse of every shape so the
        # geometry decoders (points/parts/bbox/M/Z) actually run.
        _ = reader.shapeType
        _ = reader.bbox
        for shape in reader.iterShapes():
            if shape is None:
                continue
            _ = shape.shapeType
            # Materialise the geometry view (exercises the GeoJSON/coordinate
            # conversion paths on top of the raw decode).
            try:
                _ = shape.__geo_interface__
            except Exception:
                pass
    except (
        shapefile.ShapefileException,
        ValueError,
        struct.error,
        IndexError,
        KeyError,
        OverflowError,
        UnicodeDecodeError,
        MemoryError,
        ZeroDivisionError,
        EOFError,
    ):
        # Expected ways pyshp rejects a malformed shapefile — not a defect.
        pass


def _main() -> None:
    # Optional Atheris entry point (only used for local pure-Python runs;
    # the commit-image target is the native libFuzzer ELF built by build.sh).
    import sys

    import atheris  # noqa: PLC0415  (optional dependency, local use only)

    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    _main()

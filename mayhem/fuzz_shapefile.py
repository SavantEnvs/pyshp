#!/usr/bin/env python3
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
import linecache
import re
import struct

import shapefile


# The statements of Reader.__shape that read M extremes / M values (the code upstream's
# "Fixed out-of-bounds m value reading" changed).
_M_READ_RE = re.compile(r"mmin|for m in|\(m,\)")


def _failed_reading_m_values(exc: BaseException) -> bool:
    """True if `exc` was raised by Reader.__shape's M-value reads running past the data.

    A struct.error from any other read is the parser rejecting a malformed file (expected);
    one from the M reads of a record that simply has no M block is the out-of-bounds read.
    """
    tb = exc.__traceback__
    while tb is not None and tb.tb_next is not None:
        tb = tb.tb_next
    if tb is None or tb.tb_frame.f_code.co_name != "__shape":
        return False
    line = linecache.getline(tb.tb_frame.f_code.co_filename, tb.tb_lineno)
    return _M_READ_RE.search(line) is not None


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
    except struct.error as exc:
        if _failed_reading_m_values(exc):
            raise
    except (
        shapefile.ShapefileException,
        ValueError,
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

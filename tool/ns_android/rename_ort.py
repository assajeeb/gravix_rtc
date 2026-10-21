"""Gravix-private ONNX Runtime: renames the release libonnxruntime.so to
libgxort.so by rewriting its DT_SONAME string in .dynstr in place (same
length, NUL padded), so an app's own libonnxruntime.so never collides with
ours (file name or soname). Usage: python3 -I rename_ort.py <in.so> <out.so>
Input = dfn3-spike release bundled/android/arm64-v8a/libonnxruntime.so
(sha256 bb17947332ce9cf6cb43d740a0cef3742f464326e6f7b277fc8d2a7214659092)."""
import hashlib, struct, sys

OLD, NEW = b"libonnxruntime.so", b"libgxort.so"
IN_SHA = "bb17947332ce9cf6cb43d740a0cef3742f464326e6f7b277fc8d2a7214659092"


def main(src, dst):
    data = bytearray(open(src, "rb").read())
    assert hashlib.sha256(data).hexdigest() == IN_SHA, "unexpected input"
    assert data[:4] == b"\x7fELF" and data[4] == 2 and data[5] == 1, "ELF64 LE only"
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    secs = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
    names_off = secs[shstrndx][4]
    def name(s):
        o = names_off + s[0]
        return bytes(data[o:data.index(0, o)]).decode()
    dynstr = next(s for s in secs if name(s) == ".dynstr")
    dynamic = next(s for s in secs if name(s) == ".dynamic")
    # DT_SONAME (14) offset into .dynstr
    soname = None
    for i in range(dynamic[5] // 16):
        tag, val = struct.unpack_from("<qQ", data, dynamic[4] + i * 16)
        if tag == 14:
            soname = val
    assert soname is not None
    at = dynstr[4] + soname
    assert bytes(data[at:at + len(OLD) + 1]) == OLD + b"\0", "soname string not found"
    # no other dynamic entry may point inside the string we shorten
    for i in range(dynamic[5] // 16):
        tag, val = struct.unpack_from("<qQ", data, dynamic[4] + i * 16)
        if tag in (1, 14, 15, 29) and tag != 14:
            assert not (soname < val <= soname + len(OLD)), "shared dynstr tail"
    data[at:at + len(OLD)] = NEW + b"\0" * (len(OLD) - len(NEW))
    open(dst, "wb").write(data)
    print("ok", dst, hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

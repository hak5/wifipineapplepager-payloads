# PyUSB source

PyUSB 1.3.1, distributed under the included BSD 3-Clause license. All `.py` files in this directory were extracted without source edits from the official pure-Python PyPI wheel.

- Package: https://pypi.org/project/pyusb/1.3.1/
- Upstream: https://github.com/pyusb/pyusb/tree/v1.3.1
- Wheel: `pyusb-1.3.1-py3-none-any.whl`
- SHA-256: `bf9b754557af4717fe80c2b07cc2b923a9151f5c08d17bdb5345dac09d6a0430`
- Reproduction: download that pinned wheel with `python -m pip download --no-deps --only-binary=:all: pyusb==1.3.1 --dest research/wheels`, then run `python tools/vendor_pyusb.py` from the project root.

Only Python source and this notice are distributed. No wheel, native USB library, bytecode or generated executable is embedded in the payload. The Pager supplies libusb through its package feed.

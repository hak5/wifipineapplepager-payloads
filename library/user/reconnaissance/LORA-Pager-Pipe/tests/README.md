# Run the offline tests

Run these tests on a development computer with Python 3.11 or newer and Bash. The `cryptography` Python package enables the AES and Ed25519 fixture tests; those tests report explicit skips if it is absent. The Windows startup tests use Git Bash at its standard installation path. No test requires a connected Pager or radio, and no test installs packages or uploads captures. Radio, package-manager and upload transports are simulated.

From the directory containing `tests/`:

```sh
python3 -m unittest discover -s tests -v
```

On Windows, use `py -3` in place of `python3` if needed. The symbolic-link configuration check can be skipped when the account lacks permission to create symbolic links; the report must retain that skip rather than count it as a pass. Native UI startup tests report a skip if Bash is unavailable.

The same suite supports both source layouts:

- Development repository: `payload/lpp.py`, `payload/lib/`, `tests/`, `tools/audit_session.py`.
- Upstream payload folder: `lpp.py`, `lib/`, `tests/`, `tools/audit_session.py`.

The helper `lpp_test_paths.py` resolves only those files beside the test suite. It does not import a separate development checkout. Keep `runtime_harness.sh` with the tests and retain the standalone audit tool; the capture-consistency tests execute that tool against temporary synthetic sessions.

For a shell syntax check, run `bash -n payload.sh` in an upstream payload folder, or `bash -n payload/payload.sh` in the development repository.

These checks validate parsers, local storage, the content-redacted audit, configuration, export and upload state handling, and mocked native UI lifecycle behavior. They do not establish physical radio reception, GNSS acquisition, native screen rendering, or live service acceptance. See `docs/VALIDATION.md` for separately recorded hardware evidence.

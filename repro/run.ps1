$ErrorActionPreference = "Stop"

python -m pip install --disable-pip-version-check --no-cache-dir "Pillow==12.3.0"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

python -c "import sys, sysconfig; assert sysconfig.get_config_var('Py_GIL_DISABLED') == 1; assert not sys._is_gil_enabled(); print('PYTHON_314T_PUBLIC_REPRO=PASS')"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

python repro/p6_concurrency.py
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

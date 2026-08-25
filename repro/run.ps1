$ErrorActionPreference = "Stop"

Write-Host "SANITIZED VECTOR AGGREGATION KERNEL DIAGNOSTIC"
Write-Host "This is not private application, contract, packaging, or acceptance evidence."

python -m pip install --disable-pip-version-check --only-binary=:all: numpy==2.5.2
python repro/analysis_vectorization_kernel.py

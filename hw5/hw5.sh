#!/bin/bash
set -e

pip install -q --upgrade "prefect>=3" || pip install -q --break-system-packages --upgrade "prefect>=3"
cd ~
python3 hw5_prefect.py

#!/bin/bash
# Class-day GPU capacity: keep the presenter 4-L4 node and add three 2-L4 nodes.
# Not part of full-setup.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/scale-gpu.sh" --4l4 1 --2l4 3

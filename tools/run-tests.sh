#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
prove -Ilib -It/lib -r t/

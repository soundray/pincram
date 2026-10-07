#!/bin/bash
# Unit tests of pincram-image (numpy reference, plus seg_maths equivalence when seg_maths is on the PATH)
. "$(dirname "$0")/lib.sh"
if python3 -c 'import numpy, scipy, nibabel' 2>/dev/null ; then
    assert "pincram-image unit tests" python3 "$testsdir"/image-unit.py
else
    echo "  skip  pincram-image unit tests: python3 with numpy, scipy and nibabel not available"
fi
report

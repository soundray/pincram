Jaccard means over targets. Masks compared: input = the input mask given to pincram -mask;
output = pincram's parenchyma.nii.gz; TBV = verified total brain volume, binarized
shared/reference/atlases-hammers-scaled-with-flipped-n60/icmasked/<t>.nii.gz; plain = pincram
output without -mask. Post-hoc rows apply the refine-band step to the no-band output.

| condition | band | n | input vs TBV | output vs TBV | output - plain (vs TBV), paired | better than plain | output vs plain | output vs input | time (s) |
|---|---|---|---|---|---|---|---|---|---|
| plain |  | 10 |  | 0.9483 |  |  | 1.0000 |  | 352 |
| dilate3 | 2 (post hoc) | 10 | 0.8413 | 0.9131 | -0.0352 ± 0.0096 | 0/10 | 0.9108 | 0.9209 | |
| dilate3 | 4 (post hoc) | 10 | 0.8413 | 0.9522 | +0.0040 ± 0.0105 | 9/10 | 0.9686 | 0.8474 | |
| dilate3 | 8 (post hoc) | 10 | 0.8413 | 0.9397 | -0.0085 ± 0.0230 | 3/10 | 0.9660 | 0.8334 | |
| dilate3 |  | 10 | 0.8413 | 0.9365 | -0.0117 ± 0.0310 | 2/10 | 0.9641 | 0.8301 | 296 |
| erode3 | 2 (post hoc) | 10 | 0.7233 | 0.8764 | -0.0719 ± 0.0130 | 0/10 | 0.8734 | 0.8246 | |
| erode3 | 4 (post hoc) | 10 | 0.7233 | 0.9553 | +0.0071 ± 0.0064 | 10/10 | 0.9752 | 0.7252 | |
| erode3 | 8 (post hoc) | 10 | 0.7233 | 0.9505 | +0.0022 ± 0.0058 | 6/10 | 0.9790 | 0.7192 | |
| erode3 |  | 10 | 0.7233 | 0.9503 | +0.0020 ± 0.0058 | 5/10 | 0.9792 | 0.7190 | 306 |
| hdbet | 2 (post hoc) | 10 | 0.9423 | 0.9500 | +0.0017 ± 0.0043 | 5/10 | 0.9755 | 0.9588 | |
| hdbet | 4 (post hoc) | 10 | 0.9423 | 0.9492 | +0.0009 ± 0.0030 | 5/10 | 0.9796 | 0.9516 | |
| hdbet | 8 (post hoc) | 10 | 0.9423 | 0.9484 | +0.0001 ± 0.0031 | 5/10 | 0.9804 | 0.9498 | |
| hdbet |  | 10 | 0.9423 | 0.9483 | +0.0001 ± 0.0030 | 5/10 | 0.9804 | 0.9497 | 300 |
| hdbet | 4 | 10 | 0.9423 | 0.9492 | +0.0009 ± 0.0030 | 5/10 | 0.9796 | 0.9516 | 298 |
| random3 | 2 (post hoc) | 10 | 0.8410 | 0.9085 | -0.0398 ± 0.0082 | 0/10 | 0.9206 | 0.8918 | |
| random3 | 4 (post hoc) | 10 | 0.8410 | 0.9446 | -0.0037 ± 0.0064 | 1/10 | 0.9704 | 0.8402 | |
| random3 | 8 (post hoc) | 10 | 0.8410 | 0.9500 | +0.0018 ± 0.0063 | 7/10 | 0.9801 | 0.8299 | |
| random3 |  | 10 | 0.8410 | 0.9500 | +0.0017 ± 0.0062 | 6/10 | 0.9802 | 0.8297 | 306 |

In-pipeline -refine-band minus post hoc on the separate no-band run (output vs TBV): mean +0.0000, max |d| 0.0000 (n=10)

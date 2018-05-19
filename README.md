Brain extraction using label propagation and group agreement.

Pincram takes as input

* a target image -- T1-weighted 3D magnetic resonance (MR) volume of the human brain in NIfTI format

* an atlas database consisting of reference MR images and corresponding binary segmentations (total brain volume masks and intracranial volume masks).

It produces

* a total brain volume mask

* an intracranial volume mask

* optionally a probabilistic segmentation of the total brain

corresponding to the target image.

Pincram works with GNU parallel and PBS to parallelize the atlas-target registrations.

## Dependencies

* IRTK (https://github.com/BioMedIA/IRTK; a port to MIRTK is in development)

* NiftySeg (http://cmictig.cs.ucl.ac.uk/wiki/index.php/NiftySeg).

## See also

http://soundray.org/pincram

## Instructions

Add pincram directory to PATH.  Copy common-template to common and adapt to system.  Call `pincram.sh` for usage.

## If you use this software for your research

Please cite: Heckemann RA, Ledig C, Gray KR, Aljabar P, Rueckert D, Hajnal JV, Hammers A. Brain Extraction Using Label Propagation and Group Agreement: Pincram. PLOS ONE. 2015 Jul 10;10(7):e0129211.

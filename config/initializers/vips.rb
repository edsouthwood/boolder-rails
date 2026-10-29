# Refuse libvips loaders that libvips itself flags as "untrusted" (not fuzzed or
# hardened against hostile input, e.g. matload, the MATLAB loader). Uploaded files are
# only ever photos, so the common loaders (JPEG, PNG, HEIC, WebP…) are all we need, and
# a file disguised as an image can't reach the risky ones when a variant is generated.
require "vips"

Vips.block_untrusted(true)

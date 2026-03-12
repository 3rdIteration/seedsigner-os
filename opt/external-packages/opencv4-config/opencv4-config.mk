# Improve build reproducibility for OpenCV4.
# OpenCV's cmake build may not fully inherit the toolchain's prefix-map flags
# set by BR2_REPRODUCIBLE, causing non-deterministic build paths embedded in
# the binary (libopencv_core.so). These flags normalise source file references
# so that builds on different machines produce identical output.
OPENCV4_CONF_OPTS += \
	-DCMAKE_C_FLAGS_INIT="-ffile-prefix-map=$(BASE_DIR)=. -fdebug-prefix-map=$(BASE_DIR)=." \
	-DCMAKE_CXX_FLAGS_INIT="-ffile-prefix-map=$(BASE_DIR)=. -fdebug-prefix-map=$(BASE_DIR)=."
OPENCV4_MAKE_ENV += SOURCE_DATE_EPOCH=0

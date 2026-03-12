# Disable IPA module signing for reproducible builds.
# Without this, libcamera generates a fresh RSA key per build to sign the
# ipa_rpi_vc4.so IPA module, producing different signatures every build.
# The IPA will run out-of-process via IPC instead, which is fine for
# SeedSigner's low-framerate QR scanning use case.
#
# libcamera v0.3.2 does not expose a meson option for this; signing is
# controlled by whether openssl is found at configure time.  We patch
# the meson build to skip the signing block entirely.
define LIBCAMERA_DISABLE_IPA_SIGNING
	$(SED) 's/if openssl\.found()/if false/' $(@D)/src/meson.build
endef
LIBCAMERA_POST_EXTRACT_HOOKS += LIBCAMERA_DISABLE_IPA_SIGNING

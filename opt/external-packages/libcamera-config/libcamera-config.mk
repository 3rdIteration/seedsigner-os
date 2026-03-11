# Disable IPA module signing for reproducible builds.
# Without this, libcamera generates a fresh RSA key per build to sign the
# ipa_rpi_vc4.so IPA module, producing different signatures every build.
# The IPA will run out-of-process via IPC instead, which is fine for
# SeedSigner's low-framerate QR scanning use case.
LIBCAMERA_CONF_OPTS += -Dipa_sign_module=disabled

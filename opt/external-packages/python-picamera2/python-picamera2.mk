################################################################################
#
# python-picamera2
#
################################################################################

PYTHON_PICAMERA2_VERSION = 0.3.34
PYTHON_PICAMERA2_SITE = https://files.pythonhosted.org/packages/b1/f3/4cb82c4d39b5573fd19257c6ff08b99b5506a0201d8bbb1cf8f1c67cd8c9
PYTHON_PICAMERA2_SOURCE = picamera2-$(PYTHON_PICAMERA2_VERSION).tar.gz
PYTHON_PICAMERA2_LICENSE = BSD-2-Clause
PYTHON_PICAMERA2_LICENSE_FILES = LICENSE
PYTHON_PICAMERA2_SETUP_TYPE = pep517
PYTHON_PICAMERA2_DEPENDENCIES = python-numpy libcamera

$(eval $(python-package))

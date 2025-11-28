FROM debian:12

# buildroot dependencies
RUN apt-get -qq update
RUN apt-get -y install \
locales \
lsb-release \
git \
wget \
make \
binutils \
gcc \
g++ \
patch \
gzip \
bzip2 \
perl \
tar \
cpio \
unzip \
zip \
rsync \
file \
bc \
libssl-dev \
vim \
build-essential \
libncurses-dev \
mtools \
fdisk \
dosfstools \
ccache \
python3 \
python3-pip \
python3-virtualenv \
swig \
squashfs-tools

# Locale
RUN sed -i 's/^# //g' /etc/locale.gen \
    && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN echo "LC_ALL=en_US.UTF-8" >> /etc/environment
RUN echo "LANG=en_US.UTF-8" > /etc/locale.conf

WORKDIR /opt
ENTRYPOINT ["./build.sh"]

FROM timoreymann/deterministic-zip:5.2.0 as deterministic_zip

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
libarchive-tools \
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
squashfs-tools \
strip-nondeterminism

# Locale
RUN locale-gen en_US.UTF-8  
ENV LANG en_US.UTF-8  
ENV LANGUAGE en_US:en  
ENV LC_ALL en_US.UTF-8

RUN echo "LC_ALL=en_US.UTF-8" >> /etc/environment
RUN echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
RUN echo "LANG=en_US.UTF-8" > /etc/locale.conf
RUN locale-gen en_US.UTF-8

COPY --from=deterministic_zip /bin/deterministic-zip /usr/local/bin/deterministic-zip

WORKDIR /opt
ENTRYPOINT ["./build.sh"]

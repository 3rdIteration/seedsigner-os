FROM debian:12

ARG SOURCE_DATE_EPOCH=1713811000

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
RUN locale-gen en_US.UTF-8  
ENV LANG en_US.UTF-8  
ENV LANGUAGE en_US:en  
ENV LC_ALL en_US.UTF-8

RUN echo "LC_ALL=en_US.UTF-8" >> /etc/environment
RUN echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
RUN echo "LANG=en_US.UTF-8" > /etc/locale.conf
RUN locale-gen en_US.UTF-8

ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    TZ=UTC

RUN ln -sf /usr/share/zoneinfo/UTC /etc/localtime

RUN cat <<'EOF' >/etc/profile.d/repro.sh
alias tar='tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@${SOURCE_DATE_EPOCH}'
alias gzip='gzip -n'
EOF

LABEL org.opencontainers.image.created="1970-01-01T00:00:00Z" \
      org.opencontainers.image.revision="static"

WORKDIR /opt
ENTRYPOINT ["./build.sh"]

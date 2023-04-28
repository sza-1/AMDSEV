# syntax=docker/dockerfile:1

FROM ubuntu:22.04 as base

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked apt-get update

FROM base as linux

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked apt-get --assume-yes --no-install-recommends install \
	bc \
	bison \
	build-essential \
	ca-certificates \
	cpio \
	flex \
	git \
	libelf-dev \
	libssl-dev \
	linux-image-oem-22.04c \
	rsync \
	zstd

RUN git clone --branch=snp-host-latest --depth=1 https://github.com/AMDESE/linux.git && cd linux && cp /boot/config-* .config && \
	./scripts/config --disable AMD_MEM_ENCRYPT_ACTIVE_BY_DEFAULT && \
	./scripts/config --disable DEBUG_PREEMPT && \
	./scripts/config --disable IOMMU_DEFAULT_PASSTHROUGH && \
	./scripts/config --disable LOCALVERSION_AUTO && \
	./scripts/config --disable PREEMPT_COUNT && \
	./scripts/config --disable PREEMPT_DYNAMIC && \
	./scripts/config --disable PREEMPTION && \
	./scripts/config --disable SYSTEM_REVOCATION_KEYS && \
	./scripts/config --disable SYSTEM_TRUSTED_KEYS && \
	./scripts/config --enable AMD_MEM_ENCRYPT && \
	./scripts/config --enable DEBUG_INFO && \
	./scripts/config --enable DEBUG_INFO_REDUCED && \
	./scripts/config --enable KVM_AMD_SEV && \
	./scripts/config --module CRYPTO_DEV_CCP_DD && \
	./scripts/config --module SEV_GUEST && \
	./scripts/config --set-str LOCALVERSION "-amd-$(git describe --always)" && \
	make --jobs="$(nproc)" olddefconfig bindeb-pkg

FROM base as ovmf

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked apt-get --assume-yes --no-install-recommends install \
	acpica-tools \
	build-essential \
	ca-certificates \
	git \
	nasm \
	python-is-python3 \
	uuid-dev

SHELL ["/usr/bin/bash", "-c"]

RUN git clone --branch=snp-latest --depth=1 --recurse-submodules --shallow-submodules https://github.com/AMDESE/ovmf.git && cd ovmf && make --directory=BaseTools --jobs="$(nproc)" && touch OvmfPkg/AmdSev/Grub/grub.efi && . ./edksetup.sh && build --arch=X64 --platform=OvmfPkg/AmdSev/AmdSevX64.dsc --tagname=GCC5

FROM base as qemu

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked apt-get --assume-yes --no-install-recommends install \
	build-essential \
	ca-certificates \
	git \
	libglib2.0-dev \
	libpixman-1-dev \
	libslirp-dev \
	ninja-build \
	pkg-config

RUN git clone --branch=snp-latest --depth=1 https://github.com/AMDESE/qemu.git && cd qemu && ./configure --enable-slirp --prefix=/opt/amd --target-list=x86_64-softmmu && make --jobs="$(nproc)" install

FROM base as boot

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
	apt-get --assume-yes --no-install-recommends install \
		binutils \
		ca-certificates \
		initramfs-tools \
		python3-pefile \
		systemd \
		wget && \
	wget https://raw.githubusercontent.com/systemd/systemd/main/src/ukify/ukify.py

COPY --from=linux --link /*.deb .

RUN dpkg --install *.deb

ARG CMDLINE

RUN python3 ukify.py --cmdline="${CMDLINE}" /boot/vmlinuz-* /boot/initrd.img-*

FROM scratch

COPY --from=boot --link /*.efi /boot /boot/

COPY --from=linux --link /*.buildinfo /*.changes /*.deb /linux/

COPY --from=ovmf --link /ovmf/Build/AmdSev/DEBUG_GCC5/FV/OVMF.fd /opt/amd/share/qemu/

COPY --from=qemu --link /opt/amd /opt/amd

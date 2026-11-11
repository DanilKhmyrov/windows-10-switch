FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang-14 lld-14 llvm-14 osslsigncode python3 p7zip-full msitools cabextract file
RUN ln -s /usr/bin/lld-link-14 /usr/local/bin/lld-link \
    && ln -s /usr/bin/clang-14 /usr/local/bin/clang
RUN apt-get install -y --no-install-recommends ntfs-3g libhivex-bin openssl
RUN apt-get install -y --no-install-recommends libwin-hivex-perl
RUN apt-get install -y --no-install-recommends wimtools
RUN apt-get install -y --no-install-recommends aria2 ca-certificates
RUN apt-get install -y --no-install-recommends chntpw

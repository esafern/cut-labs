FROM ubuntu:22.04
RUN apt-get update && apt-get install -y wireguard-tools iproute2 iputils-ping net-tools netcat-openbsd tcpdump && rm -rf /var/lib/apt/lists/*
CMD ["bash"]

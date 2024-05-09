#!/bin/bash

# Wait for hosts or files to be available before starting
if [[ -n "$WAIT_HOSTS" ]] || [[ -n "$WAIT_PATHS" ]]; then
	/wait
fi

# Create init config
if [[ ! -f "/etc/ocserv/ocserv.conf" ]]; then
	cat > ocserv.conf <<- EOCONF
	# authentication via linux user
	# auth = pam

	# authentication via passwd file
	auth = "plain[passwd=/etc/ocserv/ocpasswd]"

	tcp-port = 443
	udp-port = 443

	run-as-user = nobody
	run-as-group = daemon
	socket-file = /var/run/ocserv-socket

	max-clients = 100
	max-same-clients = 0

	tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-RSA:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1:-VERS-TLS1.2"

	device = vpns

	ipv4-network = 172.20.0.0/24
	ipv4-netmask = 255.255.255.0
	ipv6-network = 2001:db8:2::/64
	ipv6-subnet-prefix = 112

	route = 172.20.0.0/24
	route = 2001:db8:2::/64
	no-route = 10.0.0.0/8
	no-route = 100.64.0.0/10
	no-route = 169.254.0.0/16
	no-route = 192.0.0.0/24
	no-route = 192.168.0.0/16
	no-route = 224.0.0.0/24
	no-route = 240.0.0.0/4
	no-route = 172.16.0.0/12
	no-route = 127.0.0.0/8
	no-route = 255.255.255.255/32

	tunnel-all-dns = true

	dns = 1.1.1.1
	dns = 2606:4700:4700::1111
	dns = 2606:4700:4700::1001
	dns = 8.8.8.8
	dns = 2001:4860:4860::8888
	dns = 2001:4860:4860::8844

	# custom config file must as same as username or groupname
	config-per-user = /etc/ocserv/config-per-user/
	config-per-group = /etc/ocserv/config-per-group/
	predictable-ips = true

	# dead peer detection and keepalive in seconds
	keepalive = 290
	dpd = 90
	mobile-dpd = 1800
	switch-to-tcp-timeout = 25
	try-mtu-discovery = true

	# Uncomment if you are using haproxy
	# listen-proxy-proto = true

	# Uncomment to enable compression negotiation (LZS, LZ4)
	# And set minimum under a packet will not be compressed.
	# Compression is designed to save bandwidth, but it can be
	# bring a little latency. The default size is 256 bytes,
	# to avoid latency for VoIP packets. Modify it if the clients
	# typically use compression as well of VoIP with codecs that
	# exceed the default value.
	# compression = true
	# no-compress-limit = 256

	# Change below to true if you want to support older version cisco clients
	dtls-legacy = false
	cisco-client-compat = false

	ping-leases = false
	match-tls-dtls-ciphers = true

	use-occtl = true
	log-level = 1
	EOCONF

fi

# Create certs if no local or letsencrypt certs
if [[ ! -f "/etc/ocserv/server.cert" ]] && [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then

	IPV4=$(timeout 3 curl -s https://ipinfo.io/ip || echo "")
	IPV6=$(timeout 3 curl -s https://6.ipinfo.io/ip || echo "")
	if [[ -z $DOMAIN ]]; then

		# Create self signed certificate
		CN="vpn.example.com"
		ORG="Organization"
		DAYS=3650
		if [[ -z "$IPV4" ]] && [[ -z "$IPV6" ]]; then
			echo "Failed to get public IP address"
			exit 1
		fi

		certtool --generate-privkey --outfile ca-key.pem
		cat > ca.tmpl <<-EOCA
		cn = "$CN"
		organization = "$ORG"
		serial = 1
		expiration_days = $DAYS
		ca
		signing_key
		cert_signing_key
		crl_signing_key
		EOCA
		certtool --generate-self-signed --load-privkey ca-key.pem --template ca.tmpl --outfile ca.pem
		certtool --generate-privkey --outfile server-key.pem
		cat > server.tmpl <<-EOSRV
		cn = "$CN"
		organization = "$ORG"
    serial = 2
		expiration_days = $DAYS
		signing_key
		encryption_key
		tls_www_server
		# dns_name = "<your-hostname>"
		ip_address = "${IPV4:-$IPV6}"
		EOSRV
		certtool --generate-certificate --load-privkey server-key.pem --load-ca-certificate ca.pem --load-ca-privkey ca-key.pem --template server.tmpl --outfile server-cert.pem
		echo "server-cert = /etc/ocserv/server-cert.pem" >> ocserv.conf
		echo "server-key = /etc/ocserv/server-key.pem" >> ocserv.conf

	else

		# Create letsencrypt certificate
		if [[ -f "/etc/ocserv/cloudflare.ini" ]]; then
			if [[ -z $EMAIL ]]; then
				certbot certonly --dns-cloudflare --non-interactive --agree-tos \
				--dns-cloudflare-credentials /etc/ocserv/cloudflare.ini \
				-d $DOMAIN \
				--register-unsafely-without-email
			else
				certbot certonly --dns-cloudflare --non-interactive --agree-tos \
				--dns-cloudflare-credentials /etc/ocserv/cloudflare.ini \
				-d $DOMAIN \
				--email $EMAIL
			fi
		else
			if [[ -z $EMAIL ]]; then
				certbot certonly --standalone --non-interactive --agree-tos \
				-d $DOMAIN \
				--register-unsafely-without-email
			else
				certbot certonly --standalone --non-interactive --agree-tos \
				-d $DOMAIN \
				--email $EMAIL
			fi
		fi

		cron_file="/var/spool/cron/crontabs/root"
		cron_config='15 00 * * * certbot renew --quiet && systemctl restart ocserv'
		if ! grep -Fxq "$cron_config" $cron_file; then
			echo "$cron_config" >> $cron_file
		fi
		ocserv_config_file="/etc/ocserv/ocserv.conf"
		cert_config="server-cert = /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
		key_config="server-key = /etc/letsencrypt/live/$DOMAIN/privkey.pem"
		if ! grep -Fxq "$cert_config" $ocserv_config_file; then
			echo "$cert_config" >> $ocserv_config_file
			echo "$key_config" >> $ocserv_config_file
		fi
		service cron restart

	fi

fi

# Create init user for PAM authentication
if [[ ! -f "/etc/ocserv/ocpasswd" ]]; then

	if [[ -z $USERNAME ]] && [[ -z $PASSWORD ]]; then
		# Create specific user
		USERNAME='test'
		PASSWORD=$(openssl rand -base64 14)
	fi

	echo $PASSWORD | echo $PASSWORD | ocpasswd $USERNAME

	echo $PASSWORD > $HOME/initial_pass.txt
	echo '----------------- User Generated ------------------'
	echo "User: $USERNAME"
	echo "Pass: $PASSWORD"
	echo '---------------------------------------------------'

fi

# Enable NAT forwarding
# if you want to specific translate ip, uncomment the following line, -j MASQUERADE is dynamic way
# iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -j SNAT --to-source $(hostname -I)
iptables -t nat -A POSTROUTING -s 172.20.0.0/24 -j MASQUERADE
iptables -I FORWARD -s 172.20.0.0/24 -j ACCEPT
iptables -I FORWARD -d 172.20.0.0/24 -j ACCEPT
ip6tables -I FORWARD -s 2001:db8:2::/64 -j ACCEPT
ip6tables -I FORWARD -d 2001:db8:2::/64 -j ACCEPT
iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Enable TUN device
mkdir -p /dev/net
mknod /dev/net/tun c 10 200
chmod 600 /dev/net/tun

# Run OpennConnect Server
exec "$@"

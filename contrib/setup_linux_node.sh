#!/bin/bash

RELEASEFILE="https://github.com/coin2fly/coin2flycore/releases/download/v0.12.1.5/coin2flycore-0.12.1.5-linux64.tar.gz"
SENTINELGIT="https://github.com/coin2fly/sentinelLinux.git" # leave empty if coin has no sentinel

daemon="coin2flyd"
cli="coin2fly-cli"
stopcli="stop"
archive_path="coin2flycore-0.12.1.5/bin/"
core_dir=".coin2flycore"
config_path="$core_dir/coin2fly.conf"
node_user="coin2fly"
mainnet="12225"
disablewallet="" # risky, a lot of coins that implement zerocoin/darksend functionality break the daemon with this

# this variable is used to keep track of the upgrades to our environment
checkpoint="20180323"
installer_checkpoint="/home/$node_user/$core_dir/.installer_checkpoint"

# other variables
DISTRO=$(lsb_release -s -c)
export DEBIAN_FRONTEND=noninteractive

# environment setup, make it pretty
tred=$(tput setaf 1); tgreen=$(tput setaf 2); tyellow=$(tput setaf 3); tblue=$(tput setaf 4); tmagenta=$(tput setaf 5); tcyan=$(tput setaf 6); treset=$(tput sgr0); tclear=$(tput clear); twbg=$(tput setab 7)

# clear the screen, my ladies
echo "$tclear"

echo -e "\n$tmagenta""Masternode Install Script for $daemon$treset\n"

# checking for current user id, we should be running as root
if (( EUID != 0 )); then
	echo -e "$tred""I need to be root to run this. Please switch to root with $twbg sudo -i $treset$tred or log in directly as root, then run the command again.$treset\n"
	exit 1
fi

if [[ $(lsb_release -s -i) != "Ubuntu" ]]; then
	echo "$tred""This doesn't seem to be Ubuntu. Distribution is unsuported.\n""$treset"
	exit 1
fi

# Checking if there's a running daemon already
BINPID=$(pidof $daemon)

if (( BINPID )); then
echo "Found $tcyan$daemon$treset running with:"
	echo " * PID: $tyellow$BINPID$treset."
	BINPATH=$(readlink -f /proc/"$BINPID"/exe)
	echo " * Path: $tyellow$BINPATH$treset."
	BINUID=$(awk '/^Uid:/{print $2}' /proc/"$BINPID"/status)
	BINUSER=$(getent passwd "$BINUID" | awk -F: '{print $1}')
	echo " * Running as: $tyellow$BINUSER$treset."
	echo " * Running under: $tyellow$DISTRO$treset."
	echo "------------------------------"
	echo "Can not continue in this state. Exiting."
	exit 1
fi

function randpw {
	< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16};echo;
}

function do_updates {
	echo -e "Bringing your system up2date."
	apt update
	DEBIAN_FRONTEND=noninteractive apt upgrade -yq
	DEBIAN_FRONTEND=noninteractive apt install -yq python-virtualenv virtualenv git
}

function do_swap {
	phymem=$(free -m|awk '/^Mem:/{print $2}')
	swap=$(free -m|awk '/^Swap:/{print $2}')
	
	if (( phymem < 1536 && swap == 0 )); then
		echo -e "You seem to have less than 1.5GB RAM and no Swap. I'm adding a$tyellow 2GB Swap File$treset."
		fallocate -l 2048M /swapfile
		chmod 0600 /swapfile
		mkswap /swapfile
		swapon /swapfile
		echo "/swapfile none swap defaults 0 0" >> /etc/fstab
	fi
}

function install_sentinel {
	if [[ $SENTINELGIT ]]; then

		cat <<- EOF > /tmp/install_sentinel.sh
		#!/bin/bash
		cd -
		git clone $SENTINELGIT sentinel
		cd sentinel
		/usr/bin/virtualenv ./venv
		./venv/bin/pip install -r requirements.txt
		
		crontab -l | { cat; echo "* * * * * cd ~/sentinel && ./venv/bin/python bin/sentinel.py 2>&1 >> ~/sentinel-cron.log" ;} | crontab -
		EOF
		
		chmod +x /tmp/install_sentinel.sh
		su - "$node_user" -c "/tmp/install_sentinel.sh"
	fi
}

function download_unpack_install {
	# grabbing the new release
	FILENAME=$(basename "$RELEASEFILE")
	echo "Downloading package:"
	curl -LJO -k "$RELEASEFILE" -o "$FILENAME"

	# unpacking in /usr/local/bin, we're unpacking only the daemon and cli, don't need the rest
	tar -C /usr/bin/ -xzf "$FILENAME" --strip-components 2 "$archive_path$daemon" "$archive_path$cli"
	# remove the archive, keep it clean
	rm -f "$FILENAME"

	# making sure the files have the correct permission, maybe someone cross-compiled and moved to a non-posix filesystem
	chmod +x /usr/bin/{"$daemon","$cli"}

	# setting up wrappers so the user never calls the binary directly as root
	cat <<- EOF > /usr/local/bin/"$daemon"
	#!/bin/bash
	
	echo -e "\n"
	echo -e "Please$tred do not$treset run the daemon manually. Use$tyellow systemctl start $daemon$treset as$tred root$treset to start it (or$tgreen restart$treset)."
	echo -e "\n"
	
	if (( EUID == 0 )); then
	
		if [[ "\$@" =~ "reindex" ]]; then
			echo "It seems that you are trying to reindex the blockchain database. Please use$tyellow systemctl start $daemon-reindex$treset to do this."
			echo "I will do this for you this time."
			exec systemctl start $daemon-reindex
			exit 0
		fi
		
		echo "Please do not attempt to run the daemon as$tred root$treset. Switch to the $tgreen$node_user$treset user with:$tyellow su - $node_user$treset."
		
		if (( \$# == 0 )); then
			exec su - $node_user -c "/usr/bin/$daemon"
		else
			printf -v string '%q ' "\$@"; exec su - $node_user -c "/usr/bin/$daemon \$string"
		fi
		
	else
	
		if (( $(pidof $daemon) )); then
			echo "$tcyan$daemon is already running."
			exit 1
		fi
		
		if (( \$# == 0 )); then
			exec /usr/bin/$daemon
		else
			printf -v string '%q ' "\$@"; exec /usr/bin/$daemon "\$string"
		fi
		
	fi
	EOF
	
	chmod +x /usr/local/bin/"$daemon"
}

function install_cronjob {
	echo "Installing extra cronjob."
	
	crontab -l | { cat; echo "SHELL=/bin/bash" ;} | crontab -
	crontab -l | { cat; echo "*/15 * * * * (( (\$(curl -s http://explorer.coin2fly.com/api/getblockcount) - \$(coin2fly-cli getblockcount)) > 10 )) && systemctl restart coin2flyd-reindex" ;} | crontab -
}

function setup_initial_config {
	mkdir -p /home/"$node_user"/"$core_dir"
	
	current_ip=$(curl -s https://v4.ifconfig.co/)
	
	cat <<- EOF > /home/"$node_user"/"$config_path"
	#----
	rpcuser=rpc-$node_user
	rpcpassword=$(randpw)
	rpcallowip=127.0.0.1
	rpcthreads=8
	rpcport=12228
	#----
	listen=1
	server=1
	daemon=1
	maxconnections=256
	logtimestamp=1
	#--------------------
	externalip=$current_ip
	bind=$current_ip
	#--------------------
	EOF
	
	chown "$node_user":"$node_user" -R /home/"$node_user"/
	
	# also copy the rpc= to root's config, so root can use the rpc client
	mkdir -p ~/"$core_dir"
	grep rpc /home/"$node_user"/"$config_path" > ~/"$config_path"
}

function get_key_update_config {

	if [[ ! "$MNKEY" ]]; then
		echo -n "We are generating a new private key: "
		sleep 10 # just giving a chance to non-ssd VPS to catch-up, if we just started this for the first time
		genkey=$(su - "$node_user" -c "/usr/bin/$cli masternode genkey")
	else
		echo -n "We are using the provided key: "
		genkey="$MNKEY"
	fi
	echo "$tyellow$genkey$treset"
	
	echo "masternode=1" >> /home/"$node_user"/"$config_path"
	echo "masternodeprivkey=$genkey" >> /home/"$node_user"/"$config_path"
}

function create_upstart_conf {
	echo -e "Installing an $tyellow upstart$treset init file to keep our daemon running & auto-restarting.\n"
	echo -e "$tred""Please keep in mind this is not tested, so it may not work at all. You should be using the recommended linux distribution instead.$treset\n"
	
	cat <<- EOF > /etc/init/"$daemon".conf
	# $daemon - job file
	description "$daemon init script"
	
	# When to start the service
	start on runlevel [2345]
	
	# When to stop the service
	stop on runlevel [016]
	
	# Automatically restart process if crashed
	respawn
	expect fork
	
	setuid $node_user
	setgit $node_user
	
	exec /usr/bin/$daemon -daemon $disablewallet
	EOF
	
	echo -e "To manually stop/start the $daemon daemon, do:"
	echo -e " Start:$tyellow start $daemon$treset"
	echo -e " Stop:$tyellow stop $daemon$treset"
	echo -e "\n"
	
	start "$daemon"
}

function create_systemd_unit {
	echo "Installing a $tyellow systemd$treset service file to keep our daemon running & auto-restarting."

	cat <<- EOF > /lib/systemd/system/"$daemon".service
	[Unit]
	Description=$daemon's masternode daemon
	After=network.target
	
	[Service]
	User=$node_user
	Group=$node_user
	Type=forking
	ExecStart=/usr/bin/$daemon -daemon $disablewallet
	ExecStop=/usr/bin/$cli $stopcli
	OnFailure=$daemon-reindex.service
	Restart=always
	TimeoutStopSec=60s
	TimeoutStartSec=30s
	StartLimitInterval=120s
	StartLimitBurst=5
	
	[Install]
	WantedBy=multi-user.target
	EOF
	
	cat <<- EOF > /lib/systemd/system/"$daemon"-reindex.service
	[Unit]
	Description=$daemon's reindex
	After=network.target
	OnFailure=$daemon.service
	Conflicts=$daemon.service
	
	[Service]
	User=$node_user
	Group=$node_user
	Type=forking
	ExecStart=/usr/bin/$daemon -daemon -reindex $disablewallet
	ExecStop=/usr/bin/$cli $stopcli
	Restart=always
	TimeoutStopSec=60s
	TimeoutStartSec=30s
	StartLimitInterval=120s
	StartLimitBurst=5
	
	[Install]
	WantedBy=multi-user.target
	EOF
	
	systemctl daemon-reload
	systemctl enable "$daemon"
	systemctl start "$daemon"
	
	echo -e "To manually stop/start $tcyan$daemon$treset, please use:"
	echo -e " Start:$tyellow systemctl start $daemon$treset."
	echo -e " Stop:$tyellow systemctl stop $daemon$treset."
	echo -e "\n"
}

do_updates
do_swap

# add the user, doh
adduser --quiet $node_user --disabled-password --gecos ''

# download & install the binaries to their correct places, including wrappers
download_unpack_install
# run the daemon for the first time
setup_initial_config
su - $node_user -c "/usr/bin/$daemon $disablewallet -daemon"
# \o/ just wait a bit
sleep 3
# let's go ahead and do the fancy key stuff
get_key_update_config
# stop the daemon
su - $node_user -c "/usr/bin/$cli stop"
echo -e "\n"

install_sentinel

# proceeding...

if [[ $DISTRO == "xenial" || $DISTRO == "artful" || $DISTRO == "zesty" || $DISTRO == "bionic" ]]; then
	create_systemd_unit
elif [[ $DISTRO == "trusty" ]]; then
	create_upstart_conf
else 
	echo -e "$tred""We have no idea what Ubuntu version you are using (how did you even get this far?), so we're just gonna set up a cronjob for you to start the daemon\n$treset"
	crontab -l -u "$node_user" | { cat; echo "@reboot /usr/bin/$daemon -reindex $disablewallet" ;} | crontab -u "$node_user" -
	su - "$node_user" -c "/usr/bin/$daemon -reindex $disablewallet"
fi

install_cronjob

# set checkpoint
echo "$checkpoint" > "$installer_checkpoint"

echo -e "\n"
echo -e "Masternode setup is done on this side. You should go back to your Wallet and add this line to your$tgreen masternode.conf$reset file:\n"

echo -e "$tyellow""MN1 $tgreen$current_ip:$mainnet $genkey$tmagenta txhash txindex$treset\n"

echo -e " * replace:$tmagenta txhash$treset and$tmagenta index$treset with your correct values from$tblue masternode outputs$treset"
echo -e " *$tyellow MN1$treset can be anything you want, just keep it in one word\n"
echo -e "After you edit the$tgreen masternode.conf$treset file and restart your wallet, you can$tmagenta start alias$treset from the Masternode Tab in the wallet.\n"

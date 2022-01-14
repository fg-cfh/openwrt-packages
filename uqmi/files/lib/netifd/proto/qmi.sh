#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_qmi_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_string apn
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pincode
	proto_config_add_int delay
	proto_config_add_string modes
	proto_config_add_string pdptype
	proto_config_add_int profile
	proto_config_add_boolean dhcp
	proto_config_add_boolean dhcpv6
	proto_config_add_boolean autoconnect
	proto_config_add_int plmn
	proto_config_add_int timeout
	proto_config_add_int mtu
	proto_config_add_defaults
}

proto_qmi_setup() {
	local interface="$1"
	local dataformat connstat plmn_mode mcc mnc
	local device apn auth username password pincode delay modes pdptype
	local profile dhcp dhcpv6 autoconnect plmn timeout mtu $PROTO_DEFAULT_OPTIONS
	local ip4table ip6table
	local cid_4 pdh_4 cid_6 pdh_6
	local ip_6 ip_prefix_length gateway_6 dns1_6 dns2_6
	local update_default_apn=false
	local x=0

	json_get_vars device apn auth username password pincode delay modes
	json_get_vars pdptype profile dhcp dhcpv6 autoconnect plmn ip4table
	json_get_vars ip6table timeout mtu $PROTO_DEFAULT_OPTIONS

	[ "$timeout" = "" ] && timeout="10"

	[ "$metric" = "" ] && metric="0"

	[ -n "$ctl_device" ] && device=$ctl_device

	[ -n "$device" ] || {
		echo "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	}

	[ -n "$delay" ] && sleep "$delay"

	device="$(readlink -f $device)"
	[ -c "$device" ] || {
		echo "The specified control device does not exist"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	}

	devname="$(basename "$device")"
	devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
	ifname="$( ls "$devpath"/net )"
	[ -n "$ifname" ] || {
		echo "The interface could not be found."
		proto_notify_error "$interface" NO_IFACE
		proto_set_available "$interface" 0
		return 1
	}

	[ -n "$mtu" ] && {
		echo "Setting MTU to $mtu"
		/sbin/ip link set dev $ifname mtu $mtu
	}

# Check PIN status
	pin_status=$(uqmi -s -d "$device" --uim-get-sim-state -t 2000 2>&1)
	while [ ${pin_status:0:1} = 'R' ]
	do
		echo "Waiting for modem to initiate"
		sleep 2
		pin_status=$(uqmi -s -d "$device" --uim-get-sim-state -t 2000 2>&1)
	done
	if [ ${pin_status:0:1} != '{' ]
	then
		echo Can´t check the PINcode
		echo Make sure that PINcode is de-activated
	else
		json_load $pin_status
		json_get_var pin1_status pin1_status
                case $pin1_status in
                        disabled)
                                echo "PINcode disabled"
                                ;;
                        blocked)
                                echo "SIM locked PUK required"
                                proto_notify_error "$interface" PUK_NEEDED
                                proto_block_restart "$interface"
                                return 1
                                ;;
                        not_verified)
                                if [ -n "$pincode" ]
                                then
                                        pin_verified=$(uqmi -s -d "$device" --uim-verify-pin1 "$pincode")
                                        if [ -n "$pin_verified" ]
                                        then
                                                echo "Unable to verify PIN. $pin_verified"
                                                proto_notify_error "$interface" PIN_FAILED
                                                proto_block_restart "$interface"
                                                return 1
                                        else
                                                echo "PINcode verified"
                                        fi
                                else
                                        echo "PINcode required but not specified"
                                        proto_notify_error "$interface" PIN_NOT_SPECIFIED
                                        proto_block_restart "$interface"
                                        return 1
                                fi
                                ;;
                        verified)
                                echo "PIN already verified"
                                ;;
                        *)
                                echo "PIN status failed: $pin1_status"
                                proto_notify_error "$interface" PIN_STATUS_FAILED
                                proto_block_restart "$interface"
                                return 1
                                ;;
                esac
	fi

# Check data format
	uqmi -d "$device"  --wda-set-data-format 802.3 > /dev/null 2>&1
	data_format=$(uqmi -d "$device" --wda-get-data-format)
	if [ "$data_format" = '"raw-ip"' ]
	then
		if [ -f /sys/class/net/$ifname/qmi/raw_ip ]
		then
			echo Data format set to raw-ip
			echo "Y" > /sys/class/net/$ifname/qmi/raw_ip
		else
			echo "Device only supports raw-ip mode but missing required attribute: /sys/class/net/$ifname/qmi/raw_ip"
			proto_notify_error "$interface" DATA_FORMAT_ERROR
			proto_block_restart "$interface"
			return 1
		fi
	elif [ "$data_format" = '"802.3"' ]
	then
		echo Data format set to 802.3
	else
		echo Data format failure: $data_format
		proto_notify_error "$interface" DATA_FORMAT_FAILURE
		proto_block_restart "$interface"
		return 1
	fi

# Check default APN profile
	if [ -z "$pdptype" ] || [ -z "$auth" ]
	then
		echo "Check pdptype and auth settings"
		proto_notify_error "$interface" PDP-TYPE_OR_AUTH_MISSING
		proto_block_restart "$interface"
		return 1
	fi
	if [ $pdptype = 'ipv4' ] || [ $pdptype = 'ipv4v6' ]
	then
		pdptype_def='ipv4'
	else
		pdptype_def='ipv6'
	fi
	json_load "$(uqmi -s -d "$device" --get-default-profile-number 3gpp)"
	json_get_var default_profile default-profile
	echo Default profile number: $default_profile
	json_load "$(uqmi -s -d "$device" --get-profile-settings 3gpp,$default_profile)"
	json_get_var def_apn apn
	json_get_var def_pdptype pdp-type
	json_get_var def_username username
	json_get_var def_password password
	json_get_var def_auth auth
	[ "$def_apn" != "$apn" ] && update_default_apn=true
	[ "$def_pdptype" != "$pdptype_def" ] && update_default_apn=true
	[ "$def_username" != "$username" ] && update_default_apn=true
	[ "$def_password" != "$password" ] && update_default_apn=true
	[ "$def_auth" != "$auth" ]  && update_default_apn=true
	if [ $update_default_apn = true ]
	then
		op_mode=$(uqmi -d "$device" --get-device-operating-mode)
		if [ "$op_mode" = '"online"' ]
		then
			echo "Initiate airplane mode"
			uqmi -d "$device" --set-device-operating-mode low_power
			sleep 1
			json_load "$(uqmi -s -d "$device" --get-serving-system)"
			json_get_var registration registration
			while [ "$registration" = registered ]
			do
				sleep 2
				json_load "$(uqmi -s -d "$device" --get-serving-system)"
				json_get_var registration registration
			done
		fi
		echo Change default profile
		[ "$def_apn" != "$apn" ] && echo apn: $def_apn to $apn
		[ "$def_pdptype" != "$pdptype_def" ] && echo pdp-type: $def_pdptype to $pdptype_def
		[ "$def_username" != "$username" ] && echo username: $def_username to $username
		[ "$def_password" != "$password" ] && echo password changed
		[ "$def_auth" != "$auth" ]  && echo authentication: $def_auth to $auth
		uqmi -d "$device" --modify-profile 3gpp,$default_profile \
			--apn "$apn" \
			--pdp-type "$pdptype_def" \
			--username "$username" \
			--password "$password" \
			--auth "$auth"
	fi

# Configure profile for dual-stack
	if [ $pdptype = 'ipv4v6' ]
	then
		echo "Configure profile for dual-stack"
		dualstack_profile=$((default_profile+1))
		pdptype_ds='ipv6'
		modify_ds=$(uqmi -d "$device" --modify-profile 3gpp,$dualstack_profile \
					--apn "$apn" \
					--pdp-type "$pdptype_ds" \
					--username "$username" \
					--password "$password" \
					--auth "$auth" 2>&1)
		if [ ! -z "$modify_ds" ]
		then
			create_ds=$(uqmi -s -d "$device" --create-profile 3gpp \
						--apn "$apn" \
						--pdp-type "$pdptype_ds" \
						--username "$username" \
						--password "$password" \
						--auth "$auth" 2>&1)
			if [ ${create_ds:0:1} != '{' ]
			then
				echo "Unable to create profile for dual-stack"
				pdptype='ipv4'
			else
				json_load $create_ds
				json_get_var dualstack_profile created-profile
			fi
		fi
		echo "Dual-stack profile number: $dualstack_profile"
	fi

# Check airplane mode
	op_mode=$(uqmi -d "$device" --get-device-operating-mode)
	if [ $op_mode != '"online"' ]
	then
		echo "Airplane mode off"
		uqmi -d "$device" --set-device-operating-mode online
		sleep 1
	fi

# Check PLMN settings
	json_load "$(uqmi -s -d "$device" --get-plmn)"
	json_get_var plmn_mode mode
	if [ -z "$plmn" ] || [ "$plmn" = "0" ]
	then
		if [ $plmn_mode = automatic ]
		then
			mcc=""
			mnc=""
		else
			mcc="0"
			mnc="00"
			been_searching=false
		fi
	else
		mcc=${plmn:0:3}
		mnc=${plmn:3}
	fi
	plmn_mode=no_change
	if [ -n "$mcc" -a -n "$mnc" ]
	then
		set_plmn=$(uqmi -s -d "$device" --set-plmn --mcc $mcc --mnc $mnc 2>&1)
		if [ ! -z "$set_plmn" ]
		then
			echo "Unable to set PLMN, $set_plmn"
			proto_notify_error "$interface" PLMN_FAILED
			proto_block_restart "$interface"
			return 1
		fi
		json_load "$(uqmi -s -d "$device" --get-plmn)"
		json_get_var plmn_mode mode
		if [ $plmn_mode = automatic ]
		then
			echo "PLMN set to automatic"
			uqmi -d "$device" --network-register
		else
			json_get_var mcc mcc
			json_get_var mnc mnc
			json_get_var mnc_length mnc_length
			full_mnc=00$mnc
			if [ $mnc_length = 2 ]
			then
				full_mnc=${full_mnc: -2}
			else
				full_mnc=${full_mnc: -3}
			fi
		echo "PLMN set to mcc: $mcc mnc: $full_mnc"
		fi
	fi

# Check registered network and used radio technology
	first_registration=true
	wait_for_registration=true
	while [ "$wait_for_registration" = true ] && [ $x -lt 20 ]
	do
		[ $first_registration = false ] && sleep 3
		x=$((x+1))
		json_load "$(uqmi -s -d "$device" --get-serving-system)"
		json_get_var registration registration
		json_get_var operator plmn_description
		json_get_var plmn_mcc plmn_mcc
		json_get_var plmn_mnc plmn_mnc
		json_get_var plmn_mnc_length mnc_length
		case $registration in
			registered)
				wait_for_registration=false
				if [ "$plmn_mode" = manual ]
					then
					[ "$plmn_mcc" != "$mcc" ] && wait_for_registration=true
					[ "$plmn_mnc" != "$mnc" ] && wait_for_registration=true
					[ "$plmn_mnc_length" != "$mnc_length" ] && wait_for_registration=true
				elif [ "$plmn_mode" = automatic ]
				then
					[ $been_searching = false ] && wait_for_registration=true
				fi
				;;
			searching)
				wait_for_registration=true
				been_searching=true
				;;
			registering_denied)
				wait_for_registration=false
				if [ "$plmn_mode" = manual ]
				then
						[ "$plmn_mcc" != "$mcc" ] && wait_for_registration=true
						[ "$plmn_mnc" != "$mnc" ] && wait_for_registration=true
						[ "$plmn_mnc_length" != "$mnc_length" ] && wait_for_registration=true
				elif [ "$plmn_mode" = automatic ]
				then
						[ $been_searching = false ] && wait_for_registration=true
				fi
				;;
			*)
				wait_for_registration=true
				;;
		esac
		if [ -n "$plmn_mnc" ]
		then
			full_mnc=00$plmn_mnc
			[ $plmn_mnc_length = 2 ] && full_mnc=${full_mnc: -2} || full_mnc=${full_mnc: -3}
		else
			full_mnc=""
		fi
		echo $registration on "$plmn_mcc""$full_mnc"
		first_registration=false
	done

	signal_info=$(uqmi -s -d "$device" --get-signal-info)
	while [ ${signal_info:0:1} != '{' ]
	do
		sleep 1
		signal_info=$(uqmi -s -d "$device" --get-signal-info)
	done
	json_load $signal_info
	json_get_var radio_type type
	radio_type=$(echo "$radio_type" | awk '{print toupper($0)}')
	if [ "$registration" != registered ]
	then
		if [ -z $operator ] 
		then
			full_mnc=00$plmn_mnc
			[ $plmn_mnc_length = 2 ] && full_mnc=${full_mnc: -2} || full_mnc=${full_mnc: -3}
			operator=${plmn_mcc}${full_mnc}
		fi
		echo "Unable to register to $operator on $radio_type"
		echo "Check subscription or APN settings"
		proto_notify_error "$interface" REGISTRATION_FAILED
		proto_block_restart "$interface"
		return 1
	else
		echo "Registered to $operator on $radio_type"
		sleep 1
	fi

# Start network interface
	if [ $pdptype_def = 'ipv4' ]
	then
		cid_4=$(uqmi -s -d "$device" --get-client-id wds)
		uqmi -s -d "$device" --set-client-id wds,"$cid_4" --set-ip-family ipv4
		pdh_4=$(uqmi -s -d "$device" --set-client-id wds,"$cid_4" \
						--start-network \
						--profile $default_profile)
		if ! [ "$pdh_4" -eq "$pdh_4" ] 2> /dev/null
		then
			echo "Unable to connect with ipv4, check APN settnings"
			proto_notify_error "$interface" IPV4_APN_ERROR
			proto_block_restart "$interface"
			return 1
		else
			echo "Default profile connected with ipv4"
		fi
	elif [ $pdptype_def = 'ipv6' ]
	then
		cid_6=$(uqmi -s -d "$device" --get-client-id wds)
		uqmi -s -d "$device" --set-client-id wds,"$cid_6" --set-ip-family ipv6
		pdh_6=$(uqmi -s -d "$device" --set-client-id wds,"$cid_6" \
						--start-network \
						--profile $default_profile)
		if ! [ "$pdh_6" -eq "$pdh_6" ] 2> /dev/null
		then
			echo "Unable to connect with ipv6, check APN settnings"
			proto_notify_error "$interface" IPV6_APN_ERROR
			proto_block_restart "$interface"
			return 1
                else
                        echo "Default profile connected with ipv6"
		fi
	fi
	if [ $pdptype = 'ipv4v6' ]
	then
		cid_6=$(uqmi -s -d "$device" --get-client-id wds)
		uqmi -s -d "$device" --set-client-id wds,"$cid_6" --set-ip-family ipv6
		pdh_6=$(uqmi -s -d "$device" --set-client-id wds,"$cid_6" \
						--start-network \
						--profile $dualstack_profile)
		if ! [ "$pdh_6" -eq "$pdh_6" ] 2> /dev/null
		then
			echo "Unable to connect ipv6 dual-stack profile"
			pdh_6=''
                else
                        echo "Dual-stack ipv6 profile connected"
		fi
	fi

# Start interface
	echo "Setting up $ifname"
	proto_init_update "$ifname" 1
	proto_set_keep 1
	proto_add_data
	[ -n "$pdh_4" ] && {
		json_add_string "cid_4" "$cid_4"
		json_add_string "pdh_4" "$pdh_4"
	}
	[ -n "$pdh_6" ] && {
		json_add_string "cid_6" "$cid_6"
		json_add_string "pdh_6" "$pdh_6"
	}
	proto_close_data
	proto_send_update "$interface"

	local zone="$(fw3 -q network "$interface" 2>/dev/null)"

	[ -n "$pdh_6" ] && {
		if [ -z "$dhcpv6" -o "$dhcpv6" = 0 ]; then
			json_load "$(uqmi -s -d $device --set-client-id wds,$cid_6 --get-current-settings)"
			json_select ipv6
			json_get_var ip_6 ip
			json_get_var gateway_6 gateway
			json_get_var dns1_6 dns1
			json_get_var dns2_6 dns2
			json_get_var ip_prefix_length ip-prefix-length

			proto_init_update "$ifname" 1
			proto_set_keep 1
			proto_add_ipv6_address "$ip_6" "128"
			proto_add_ipv6_prefix "${ip_6}/${ip_prefix_length}"
			proto_add_ipv6_route "$gateway_6" "128"
			[ "$defaultroute" = 0 ] || proto_add_ipv6_route "::0" 0 "$gateway_6" "" "" "${ip_6}/${ip_prefix_length}"
			[ "$peerdns" = 0 ] || {
				proto_add_dns_server "$dns1_6"
				proto_add_dns_server "$dns2_6"
			}
			[ -n "$zone" ] && {
				proto_add_data
				json_add_string zone "$zone"
				proto_close_data
			}
			proto_send_update "$interface"
		else
			json_init
			json_add_string name "${interface}_6"
			json_add_string ifname "@$interface"
			json_add_string proto "dhcpv6"
			[ -n "$ip6table" ] && json_add_string ip6table "$ip6table"
			proto_add_dynamic_defaults
			# RFC 7278: Extend an IPv6 /64 Prefix to LAN
			json_add_string extendprefix 1
			[ -n "$zone" ] && json_add_string zone "$zone"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
		fi
	}

	[ -n "$pdh_4" ] && {
		if [ "$dhcp" = 0 ]; then
			json_load "$(uqmi -s -d $device --set-client-id wds,$cid_4 --get-current-settings)"
			json_select ipv4
			json_get_var ip_4 ip
			json_get_var gateway_4 gateway
			json_get_var dns1_4 dns1
			json_get_var dns2_4 dns2
			json_get_var subnet_4 subnet

			proto_init_update "$ifname" 1
			proto_set_keep 1
			proto_add_ipv4_address "$ip_4" "$subnet_4"
			proto_add_ipv4_route "$gateway_4" "128"
			[ "$defaultroute" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0 "$gateway_4"
			[ "$peerdns" = 0 ] || {
				proto_add_dns_server "$dns1_4"
				proto_add_dns_server "$dns2_4"
			}
			[ -n "$zone" ] && {
				proto_add_data
				json_add_string zone "$zone"
				proto_close_data
			}
			proto_send_update "$interface"
		else
			json_init
			json_add_string name "${interface}_4"
			json_add_string ifname "@$interface"
			json_add_string proto "dhcp"
			[ -n "$ip4table" ] && json_add_string ip4table "$ip4table"
			proto_add_dynamic_defaults
			[ -n "$zone" ] && json_add_string zone "$zone"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
		fi
	}
}

qmi_wds_stop() {
	local cid="$1"
	local pdh="$2"

	[ -n "$cid" ] || return

	uqmi -s -d "$device" --set-client-id wds,"$cid" \
		--stop-network 0xffffffff \
		--autoconnect > /dev/null 2>&1

	[ -n "$pdh" ] && {
		uqmi -s -d "$device" --set-client-id wds,"$cid" \
			--stop-network "$pdh" > /dev/null 2>&1
	}

	uqmi -s -d "$device" --set-client-id wds,"$cid" \
		--release-client-id wds > /dev/null 2>&1
}

proto_qmi_teardown() {
	local interface="$1"

	local device cid_4 pdh_4 cid_6 pdh_6
	json_get_vars device

	[ -n "$ctl_device" ] && device=$ctl_device

	echo "Stopping network $interface"

	json_load "$(ubus call network.interface.$interface status)"
	json_select data
	json_get_vars cid_4 pdh_4 cid_6 pdh_6

	qmi_wds_stop "$cid_4" "$pdh_4"
	qmi_wds_stop "$cid_6" "$pdh_6"

	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qmi
}

#!/bin/bash

###### Email Address ######
email="london.freenas@gmail.com"

### User-editable Parameters ###
tempWarn=40
tempCrit=45
sectorsCrit=10
testAgeWarn=5
usedWarn=90
scrubAgeWarn=30
okColor="#c9ffcc"
warnColor="#ffd6d6"
critColor="#ff0000"
altColor="#f4f4f4"

### Auto-generated Parameters ###
host=$(hostname -s)
logfile="/tmp/smart_report.tmp"
subject="Status report for ${host}"
drives=$(for drive in $(sysctl -n kern.disks); do \
	if ([ "$(smartctl -i /dev/${drive} | grep "SMART support is: Enabled")" ] && ! [ "$(smartctl -i /dev/${drive} | grep "Solid State Device")" ]); then
		printf ${drive}" "; fi done | awk '{for (i=NF; i!=0 ; i--) print $i }')
pools=$(zpool list -H -o name)
config_logfile="/tmp/config_backup_error.tmp"
tarfile="/tmp/config_backup.tar"
filename="$(date "+FreeNAS_Config_%Y-%m-%d_%H-%M-%S")"
config_subject="Config backup for ${host}"


###### Pre-formatting ######
### Set email headers ###
(
	echo "To: ${email}"
	echo "Subject: ${subject}"
	echo "Content-Type: text/html"
	echo "MIME-Version: 1.0"
	echo -e "\r\n"
) > "$logfile"

### Check config integrity ###
if ! [ "$(sqlite3 /data/freenas-v1.db "pragma integrity_check;")" == "ok" ]; then
	(
		echo "<b>Automatic backup of FreeNAS config failed! The config file is corrupted!</b>"
		echo "<b>You should correct this problem as soon as possible!</b>"
	) >> "$logfile"
fi

###### Report Summary Section (html tables) ######
### zpool status summary table ###
(
	echo "<br><br>"
	echo "<table style=\"border: 1px solid black; border-collapse: collapse;\">"
	echo "<tr><th colspan=\"9\" style=\"text-align:center; font-size:20px; height:40px; font-family:courier;\">ZPool Status Report Summary</th></tr>"
	echo "<tr>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Pool<br>Name</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Status</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Read<br>Errors</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Write<br>Errors</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Cksum<br>Errors</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Used %</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Scrub<br>Repaired<br>Bytes</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Scrub<br>Errors</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Last<br>Scrub<br>Age</th>"
	echo "</tr>"
) >> "$logfile"
poolNum=0
for pool in $pools; do
	status="$(zpool list -H -o health "$pool")"
	errors="$(zpool status "$pool" | egrep "(ONLINE|DEGRADED|FAULTED|UNAVAIL|REMOVED)[ \t]+[0-9]+")"
	readErrors=0
	for err in $(echo "$errors" | awk '{print $3}'); do
		if echo "$err" | egrep -q "[^0-9]+"; then
			readErrors=1000
			break
		fi
		readErrors=$((readErrors + err))
	done
	writeErrors=0
	for err in $(echo "$errors" | awk '{print $4}'); do
		if echo "$err" | egrep -q "[^0-9]+"; then
			writeErrors=1000
			break
		fi
		writeErrors=$((writeErrors + err))
	done
	cksumErrors=0
	for err in $(echo "$errors" | awk '{print $5}'); do
		if echo "$err" | egrep -q "[^0-9]+"; then
			cksumErrors=1000
			break
		fi
		cksumErrors=$((cksumErrors + err))
	done
	if [ "$readErrors" -gt 999 ]; then readErrors=">1K"; fi
	if [ "$writeErrors" -gt 999 ]; then writeErrors=">1K"; fi
	if [ "$cksumErrors" -gt 999 ]; then cksumErrors=">1K"; fi
	used="$(zpool list -H -p -o capacity "$pool")"
	scrubRepBytes="N/A"
	scrubErrors="N/A"
	scrubAge="N/A"
	if [ "$(zpool status "$pool" | grep "scan" | awk '{print $2}')" = "scrub" ]; then
		scrubRepBytes="$(zpool status "$pool" | grep "scan" | awk '{print $4}')"
		scrubErrors="$(zpool status "$pool" | grep "scan" | awk '{print $8}')"
		scrubDate="$(zpool status "$pool" | grep "scan" | awk '{print $15"-"$12"-"$13"_"$14}')"
		scrubTS="$(date -j -f "%Y-%b-%e_%H:%M:%S" "$scrubDate" "+%s")"
		currentTS="$(date "+%s")"
		scrubAge=$((((currentTS - scrubTS) + 43200) / 86400))
	fi
	if [ $((poolNum % 2)) == 1 ]; then bgColor="#ffffff"; else bgColor="$altColor"; fi
	poolNum=$((poolNum + 1))
	if [ "$status" != "ONLINE" ]; then statusColor="#ffd6d6"; else statusColor="$bgColor"; fi
	if [ "$readErrors" != "0" ]; then readErrorsColor="#ffd6d6"; else readErrorsColor="$bgColor"; fi
	if [ "$writeErrors" != "0" ]; then writeErrorsColor="#ffd6d6"; else writeErrorsColor="$bgColor"; fi
	if [ "$cksumErrors" != "0" ]; then cksumErrorsColor="#ffd6d6"; else cksumErrorsColor="$bgColor"; fi
	if [ "$used" -gt "$usedWarn" ]; then usedColor="#ffd6d6"; else usedColor="$bgColor"; fi
	if ( [ "$scrubRepBytes" != "N/A" ] && [ "$scrubRepBytes" != "0" ] ); then scrubRepBytesColor="#ffd6d6"; else scrubRepBytesColor="$bgColor"; fi
	if ( [ "$scrubErrors" != "N/A" ] && [ "$scrubErrors" != "0" ] ); then scrubErrorsColor="#ffd6d6"; else scrubErrorsColor="$bgColor"; fi
	if [ "$(echo "$scrubAge" | awk '{print int($1)}')" -gt "$scrubAgeWarn" ]; then scrubAgeColor="#ffd6d6"; else scrubAgeColor="$bgColor"; fi

	(
		printf "<tr style=\"background-color:%s;\">
			<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
			<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
			<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
			<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
			<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
			<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s%%</td>
			<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
			<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
			<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>
		</tr>\n" "$bgColor" "$pool" "$statusColor" "$status" "$readErrorsColor" "$readErrors" "$writeErrorsColor" "$writeErrors" "$cksumErrorsColor" \
		"$cksumErrors" "$usedColor" "$used" "$scrubRepBytesColor" "$scrubRepBytes" "$scrubErrorsColor" "$scrubErrors" "$scrubAgeColor" "$scrubAge"
	) >> "$logfile"
done
echo "</table>" >> "$logfile"

### SMART status summary table ###
(
	echo "<br><br>"
	echo "<table style=\"border: 1px solid black; border-collapse: collapse;\">"
	echo "<tr><th colspan=\"15\" style=\"text-align:center; font-size:20px; height:40px; font-family:courier;\">SMART Status Report Summary</th></tr>"
	echo "<tr>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Device</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Serial<br>Number</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">SMART<br>Status</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Temperature</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Power-On<br>Hours</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Start/Stop<br>Count</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Spin Retry<br>Count</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Reallocated<br>Sectors</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Reallocation<br>Events</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Current<br>Pending<br>Sectors</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Offline<br>Uncorrectable<br>Sectors</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">UltraDMA<br>CRC<br>Errors</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Seek<br>Error<br>Health</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Last Test<br>Age (days)</th>"
	echo "  <th style=\"text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;\">Last Test<br>Type</th></tr>"
	echo "</tr>"
) >> "$logfile"
for drive in $drives; do
	(
		smartctl -A -i /dev/"$drive" | \
		awk -v device="$drive" -v tempWarn="$tempWarn" -v tempCrit="$tempCrit" -v sectorsCrit="$sectorsCrit" -v testAgeWarn="$testAgeWarn" \
		-v okColor="$okColor" -v warnColor="$warnColor" -v critColor="$critColor" -v altColor="$altColor" \
		-v lastTestHours="$(smartctl -l selftest /dev/"$drive" | grep "# 1" | awk '{print $9}')" \
		-v lastTestType="$(smartctl -l selftest /dev/"$drive" | grep "# 1" | awk '{print $3}')" \
		-v smartStatus="$(smartctl -H /dev/"$drive" | grep "SMART overall-health" | awk '{print $6}')" ' \
		/Serial Number:/{serial=$3} \
		/Temperature_Celsius/{temp=($10 + 0)} \
		/Power_On_Hours/{onHours=$10} \
		/Start_Stop_Count/{startStop=$10} \
		/Spin_Retry_Count/{spinRetry=$10} \
		/Reallocated_Sector/{reAlloc=$10} \
		/Reallocated_Event_Count/{reAllocEvent=$10} \
		/Current_Pending_Sector/{pending=$10} \
		/Offline_Uncorrectable/{offlineUnc=$10} \
		/UDMA_CRC_Error_Count/{crcErrors=$10} \
		/Seek_Error_Rate/{seekErrorHealth=$4} \
		END {
			testAge=int((onHours - lastTestHours) / 24);
			if ((substr(device,3) + 0) % 2 == 1) bgColor = "#ffffff"; else bgColor = altColor;
			if (smartStatus != "PASSED") smartStatusColor = critColor; else smartStatusColor = okColor;
			if (temp >= tempCrit) tempColor = critColor; else if (temp >= tempWarn) tempColor = warnColor; else tempColor = bgColor;
			if (spinRetry != "0") spinRetryColor = warnColor; else spinRetryColor = bgColor;
			if ((reAlloc + 0) > sectorsCrit) reAllocColor = critColor; else if (reAlloc != 0) reAllocColor = warnColor; else reAllocColor = bgColor;
			if (reAllocEvent != "0") reAllocEventColor = warnColor; else reAllocEventColor = bgColor;
			if ((pending + 0) > sectorsCrit) pendingColor = critColor; else if (pending != 0) pendingColor = warnColor; else pendingColor = bgColor;
			if ((offlineUnc + 0) > sectorsCrit) offlineUncColor = critColor; else if (offlineUnc != 0) offlineUncColor = warnColor; else offlineUncColor = bgColor;
			if (crcErrors != "0") crcErrorsColor = warnColor; else crcErrorsColor = bgColor;
			if ((seekErrorHealth + 0) < 100) seekErrorHealthColor = warnColor; else seekErrorHealthColor = bgColor;
			if (testAge > testAgeWarn) testAgeColor = warnColor; else testAgeColor = bgColor;
			printf "<tr style=\"background-color:%s;\">" \
				"<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">/dev/%s</td>" \
				"<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%d°C</td>" \
				"<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s%%</td>" \
				"<td style=\"text-align:center; background-color:%s; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%d</td>" \
				"<td style=\"text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;\">%s</td>" \
			"</tr>\n", bgColor, device, serial, smartStatusColor, smartStatus, tempColor, temp, onHours, startStop, spinRetryColor, spinRetry, reAllocColor, reAlloc, \
			reAllocEventColor, reAllocEvent, pendingColor, pending, offlineUncColor, offlineUnc, crcErrorsColor, crcErrors, seekErrorHealthColor, seekErrorHealth, \
			testAgeColor, testAge, lastTestType;
		}'
	) >> "$logfile"
done
echo "</table>" >> "$logfile"
echo "<br><br>" >> "$logfile"


###### Detailed Report Section (monospace text) ######
echo "<pre style=\"font-size:14px\">" >> "$logfile"

### zpool status for each pool ###
for pool in $pools; do
	(
	echo "<b>########## ZPool status report for ${pool} ##########</b>"
	echo "<br>"
	zpool status -v "$pool"
	echo "<br><br>"
	) >> "$logfile"
done

### SMART status for each drive ###
for drive in $drives; do
	brand="$(smartctl -i /dev/"$drive" | grep "Model Family" | awk '{print $3, $4, $5}')"
	serial="$(smartctl -i /dev/"$drive" | grep "Serial Number" | awk '{print $3}')"
	(
	echo "<br>"
	echo "<b>########## SMART status report for ${drive} drive (${brand}: ${serial}) ##########</b>"
	smartctl -H -A -l error /dev/"$drive"
	smartctl -l selftest /dev/"$drive" | grep "# 1 \|Num" | cut -c6-
	echo "<br><br>"
	) >> "$logfile"
done
sed -i '' -e '/smartctl 6.3/d' "$logfile"
sed -i '' -e '/Copyright/d' "$logfile"
sed -i '' -e '/=== START OF READ/d' "$logfile"
sed -i '' -e '/SMART Attributes Data/d' "$logfile"
sed -i '' -e '/Vendor Specific SMART/d' "$logfile"
sed -i '' -e '/SMART Error Log Version/d' "$logfile"

### End details section ###
echo "</pre>" >> "$logfile"


###### Send backup & report ######
### Send config backup ###
if [ "$(sqlite3 /data/freenas-v1.db "pragma integrity_check;")" == "ok" ]; then
	cp /data/freenas-v1.db "/tmp/${filename}.db"
	md5 "/tmp/${filename}.db" > /tmp/config_backup.md5
	sha256 "/tmp/${filename}.db" > /tmp/config_backup.sha256
	cd "/tmp/"; tar -cf "${tarfile}" "./${filename}.db" ./config_backup.md5 ./config_backup.sha256; cd - > /dev/null
	uuencode "${tarfile}" "${filename}.tar" | mail -s "${config_subject}" "${email}"
	rm "/tmp/${filename}.db"
	rm /tmp/config_backup.md5
	rm /tmp/config_backup.sha256
	rm "${tarfile}"
fi

### Send report ###
sendmail -t < "$logfile"
rm "$logfile"
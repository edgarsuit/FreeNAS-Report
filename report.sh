#!/bin/bash
# shellcheck disable=SC1004,SC2236

#set -euxo pipefail

###### ZPool, SMART, and UPS Status Report with TrueNAS Config Backup
### Original Script By: joeschmuck
### Modified By: bidelu0hm, melp, fohlsso2, onlinepcwizard, ninpucho, isentropik, dak180
### Last Edited By: dak180

### At a minimum, enter email address and set defaultFile to 0 in the config file.
### Feel free to edit other user parameters as needed.

### Current Version: v1.8
### https://github.com/dak180/FreeNAS-Report

### Changelog:
# v1.8
#   - Accommodate both SSD and HDD temp settings
#   - Keep SAS drives in their own section
#   - Improved support for SAS and NVMe
#   - Remove all awk
#   - Add support for per drive overrides
# v1.7.5
#   - Add initial support for SAS drives
# v1.7
#   - Refactor to reduce dependence on awk
#   - Use a separate config file
#   - Add support for conveyance test
# v1.6.5
#   - HTML boundary fix, proper message ids, support for dma mailer
#   - Better support for NVMe and SSD
#   - Support for new smartmon-tools
# v1.6
#   - Actually fixed the broken borders in the tables.
#   - Split the SMART table into two tables, one for SSDs and one for HDDs.
#   - Added several options for SSD reporting.
#   - Modified the SSD table in order to capture relevant (seemingly) SSD data.
#   - Changed 'include SSD' default to true.
#   - Cleaned up minor formatting and error handling issues (tried to have the cell fill with "N/A" instead of non-sensical values).
# v1.5
#   - Added Frag%, Size, Allocated, Free for ZPool status report summary.
#   - Added Disk Size, RPM, Model to the Smart Report
#   - Added if statment so that if "Model Family" is not present script will use "Device Model" for brand in the SMART Satus report details.
#   - Added Glabel Status Report
#   - Removed Power-On time labels and added ":" as a separator.
#   - Added Power-On format to the Power-On time Header.
#   - Changed Backup default to false.
# v1.4
#   - in statusOutput changed grep to scrub: instead of scrub
#   - added elif for resilvered/resilver in progress and scrub in progress with (hopefully) som useful info fields
#   - changed the email subject to include hostname and date & time
# v1.3
#   - Added scrub duration column
#   - Fixed for FreeNAS 11.1 (thanks reven!)
#   - Fixed fields parsed out of zpool status
#   - Buffered zpool status to reduce calls to script
# v1.2
#   - Added switch for power-on time format
#   - Slimmed down table columns
#   - Fixed some shellcheck errors & other misc stuff
#   - Added .tar.gz to backup file attached to email
#   - (Still coming) Better SSD SMART support
# v1.1
#   - Config backup now attached to report email
#   - Added option to turn off config backup
#   - Added option to save backup configs in a specified directory
#   - Power-on hours in SMART summary table now listed as YY-MM-DD-HH
#   - Changed filename of config backup to exclude timestamp (just uses datestamp now)
#   - Config backup and checksum files now zipped (was just .tar before; now .tar.gz)
#   - Fixed degrees symbol in SMART table (rendered weird for a lot of people); replaced with a *
#   - Added switch to enable or disable SSDs in SMART table (SSD reporting still needs work)
#   - Added most recent Extended & Short SMART tests in drive details section (only listed one before, whichever was more recent)
#   - Reformatted user-definable parameters section
#   - Added more general comments to code
# v1.0
#   - Initial release

# Defaults
LANG="en_US.UTF-8" # Ensure date works as expected.

# Functions
function rpConfig () {
	# Write out a default config file
	tee > "${configFile}" <<"EOF"

# Set this to 0 to enable
defaultFile="1"

###### User-definable Parameters
### Email Address
email="email@address.com"

### Global table colors
okColor="#c9ffcc"	# Hex code for color to use in SMART Status column if drives pass (default is light green, #c9ffcc)
warnColor="#ffd6d6"	# Hex code for WARN color (default is light red, #ffd6d6)
critColor="#ff0000"	# Hex code for CRITICAL color (default is bright red, #ff0000)
altColor="#f4f4f4"	# Table background alternates row colors between white and this color (default is light gray, #f4f4f4)

### zpool status summary table settings
usedWarn="90"			# Pool used percentage for CRITICAL color to be used
scrubAgeWarn="30"		# Maximum age (in days) of last pool scrub before CRITICAL color will be used

### SMART status summary table settings
includeSSD="true"		# Change to "true" to include SSDs in SMART status summary table; "false" to disable
includeSAS="false"		# Change to "true" to include SAS drives in SMART status summary table; "false" to disable
lifeRemainWarn="75"		# Life remaining in the SSD at which WARNING color will be used
lifeRemainCrit="50"		# Life remaining in the SSD at which CRITICAL color will be used
totalBWWarn="100"		# Total bytes written (in TB) to the SSD at which WARNING color will be used
totalBWCrit="200"		# Total bytes written (in TB) to the SSD at which CRITICAL color will be used
tempWarn="35"			# Drive temp (in C) at which WARNING color will be used
tempCrit="40"			# Drive temp (in C) at which CRITICAL color will be used
ssdTempWarn="40"		# SSD drive temp (in C) at which WARNING color will be used
ssdTempCrit="45"		# SSD drive temp (in C) at which CRITICAL color will be used
sectorsCrit="10"		# Number of sectors per drive with errors before CRITICAL color will be used
testAgeWarn="5"			# Maximum age (in days) of last SMART test before CRITICAL color will be used
powerTimeFormat="ymdh"  # Format for power-on hours string, valid options are "ymdh", "ymd", "ym", or "y" (year month day hour)

### TrueNAS config backup settings
configBackup="false"			# Change to "false" to skip config backup (which renders next two options meaningless); "true" to keep config backups enabled
emailBackup="false"				# Change to "true" to email TrueNAS config backup
saveBackup="true"				# Change to "false" to delete TrueNAS config backup after mail is sent; "true" to keep it in dir below
backupLocation="/root/backup"	# Directory in which to save TrueNAS config backups

### UPS status summary settings
reportUPS="false"			# Change to "false" to skip reporting the status of the UPS

### General script settings
logfileLocation="/tmp"		# Directory in which to save TrueNAS log file. Can be set to /tmp.
logfileName="logfilename"	# Log file name
saveLogfile="true"			# Change to "false" to delete the log file after creation

##### Drive Overrides
# In the form: declare -A _<serial>
# And then for each override: _<serial>[<value>]="<adjustment>"
# Replace any - with _ in the serial.



EOF
	echo "Please edit the config file for your setup" >&2
	exit 0
}

function ConfigBackup () {
	local tarfile
	local fnconfigdest_version
	local fnconfigdest_date
	local filename


	# Set up file names, etc for later
	tarfile="/tmp/config_backup.tar.gz"
	fnconfigdest_version="$(< /etc/version sed -e 's:)::' -e 's:(::' -e 's: :-:' | tr -d '\n')"
	if [ "${systemType}" = "BSD" ]; then
		fnconfigdest_date="$(date -r "${runDate}" '+%Y%m%d%H%M%S')"
	else
		fnconfigdest_date="$(date -d "@${runDate}" '+%Y%m%d%H%M%S')"
	fi
	filename="${fnconfigdest_date}_${fnconfigdest_version}"

	### Test config integrity
	if [ ! "$(sqlite3 "/data/freenas-v1.db" "pragma integrity_check;")" = "ok" ]; then

		# Config integrity check failed, set MIME content type to html and print warning
		{
			tee <<- EOF
				--${boundary}
				Content-Transfer-Encoding: 8bit
				Content-Type: text/html; charset=utf-8

				<b>Automatic backup of TrueNAS configuration has failed! The configuration file is corrupted!</b>
				<b>You should correct this problem as soon as possible!</b>
				<br>
EOF
		} >> "${logfile}"
	else
		# Config integrity check passed; copy config db, generate checksums, make .tar.gz archive
		sqlite3 "/data/freenas-v1.db" ".backup main /tmp/${filename}.db"
		cp -f "/data/pwenc_secret" "/tmp/"
		if [ ! -z "${MD5SUM}" ]; then
			${MD5SUM} "/tmp/${filename}.db" > /tmp/config_backup.md5
		else
			md5sum "/tmp/${filename}.db" > /tmp/config_backup.md5
		fi
		if [ ! -z "${SHA256SUM}" ]; then
			${SHA256SUM} "/tmp/${filename}.db" > /tmp/config_backup.sha256
		else
			sha256sum "/tmp/${filename}.db" > /tmp/config_backup.sha256
		fi
		(
			cd "/tmp/" || exit;
			tar -czf "${tarfile}" "./${filename}.db" "./config_backup.md5" "./config_backup.sha256" "./pwenc_secret"
		)
		{
			if [ "${emailBackup}" = "true" ]; then
				# Write MIME section header for file attachment (encoded with base64)
				tee <<- EOF
					--${boundary}
					Content-Type: application/tar+gzip name="${filename}.tar.gz"
					Content-Disposition: attachment; filename="${filename}.tar.gz"
					Content-Transfer-Encoding: base64

EOF
				base64 "${tarfile}"
			fi

			# Write MIME section header for html content to come below
			tee <<- EOF
				--${boundary}
				Content-Transfer-Encoding: 8bit
				Content-Type: text/html; charset="utf-8"

EOF
		} >> "${logfile}"

		# If logfile saving is enabled, copy .tar.gz file to specified location before it (and everything else) is removed below
		if [ "${saveBackup}" = "true" ]; then
			cp "${tarfile}" "${backupLocation}/${filename}.tar.gz"
		fi
		rm "/tmp/${filename}.db"
		rm "/tmp/config_backup.md5"
		rm "/tmp/config_backup.sha256"
		rm "${tarfile}"
	fi
}

function ZpoolSummary () {
	{
	local pool
	local status
	local frag
	local size
	local allocated
	local free
	local errors
	local readErrors
	local err
	local writeErrors
	local cksumErrors
	local used
	local scrubRepBytes
	local scrubErrors
	local scrubAge
	local scrubDuration
	local resilver
	local statusOutput
	local bgColor
	local statusColor
	local readErrorsColor
	local writeErrorsColor
	local cksumErrorsColor
	local usedColor
	local scrubRepBytesColor
	local scrubErrorsColor
	local scrubAgeColor
	local multiDay
	local altRow
	local zfsVersion
	}

	zfsVersion="$(zpool version 2> /dev/null | head -n 1 | sed -e 's:zfs-::')"

	### zpool status summary table
	{
		# Write HTML table headers to log file; HTML in an email requires 100% in-line styling (no CSS or <style> section), hence the massive tags
		tee <<- EOF
			<br><br>
			<table style="border: 1px solid black; border-collapse: collapse;">
			<tr><th colspan="14" style="text-align:center; font-size:20px; height:40px; font-family:courier;">ZPool Status Report Summary</th></tr>
			<tr>
			<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Pool<br>Name</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Status</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Size</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Allocated</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Free</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Frag %</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Used %</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Read<br>Errors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Write<br>Errors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Cksum<br>Errors</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Scrub<br>Repaired<br>Bytes</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Scrub<br>Errors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last<br>Scrub<br>Age (days)</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last<br>Scrub<br>Duration</th>
			</tr> <!-- ${zfsVersion} -->
EOF
	} >> "${logfile}"


	altRow="false"
	for pool in "${pools[@]}"; do

		# zpool health summary
		status="$(zpool list -H -o health "${pool}")"

		# zpool fragment summary
		frag="$(zpool list -H -p -o frag "${pool}")"
		size="$(zpool list -H -o size "${pool}")"
		allocated="$(zpool list -H -o allocated "${pool}")"
		free="$(zpool list -H -o free "${pool}")"

		# Total all read, write, and checksum errors per pool
		errors="$(zpool status "${pool}" | grep -E "(ONLINE|DEGRADED|FAULTED|UNAVAIL|REMOVED)[ \\t]+[0-9]+" | tr -s '[:blank:]' ' ')"
		readErrors="0"
		for err in $(echo "${errors}" | cut -d ' ' -f "4"); do
			if echo "${err}" | grep -E -q "[^0-9]+"; then
				# Assume a non number value is > 1000
				readErrors="1000"
				break
			fi
			readErrors="$((readErrors + err))"
		done
		writeErrors="0"
		for err in $(echo "${errors}" | cut -d ' ' -f "5"); do
			if echo "${err}" | grep -E -q "[^0-9]+"; then
				# Assume a non number value is > 1000
				writeErrors="1000"
				break
			fi
			writeErrors="$((writeErrors + err))"
		done
		cksumErrors="0"
		for err in $(echo "${errors}" | cut -d ' ' -f "6"); do
			if echo "${err}" | grep -E -q "[^0-9]+"; then
				# Assume a non number value is > 1000
				cksumErrors="1000"
				break
			fi
			cksumErrors="$((cksumErrors + err))"
		done
		# Not sure why this changes values larger than 1000 to ">1K", but I guess it works, so I'm leaving it
		if [ "${readErrors}" -gt 999 ]; then readErrors=">1K"; fi
		if [ "${writeErrors}" -gt 999 ]; then writeErrors=">1K"; fi
		if [ "${cksumErrors}" -gt 999 ]; then cksumErrors=">1K"; fi

		# Get used capacity percentage of the zpool
		used="$(zpool list -H -p -o capacity "${pool}")"

		# Gather info from most recent scrub; values set to "N/A" initially and overwritten when (and if) it gathers scrub info
		scrubRepBytes="N/A"
		scrubErrors="N/A"
		scrubAge="N/A"
		scrubDuration="N/A"
		resilver=""
		local statusOutputLine
		local scrubYear
		local scrubMonth
		local scrubDay
		local scrubTime

		statusOutput="$(zpool status "${pool}")"
		statusOutputLine="$(echo "${statusOutput}" | grep "scan:" | sed -e 's:[[:blank:]]\{1,\}: :g' -e 's:^[[:blank:]]*::')"

		# normal status i.e. scrub
		if [ "$(echo "${statusOutputLine}" | cut -d ' ' -f "2,3")" = "scrub repaired" ]; then
			{
			multiDay="$(echo "${statusOutputLine}" | grep -c "days")"
			scrubRepBytes="$(echo "${statusOutputLine}" | cut -d ' ' -f "4" | sed -e 's:B::')"

			# Convert time/datestamp format presented by zpool status, compare to current date, calculate scrub age
			if [ "${multiDay}" -ge 1 ] ; then
				# We should test the version of zfs because there still is no json output
				scrubYear="$(echo "${statusOutputLine}" | cut -d ' ' -f "17")"
				scrubMonth="$(echo "${statusOutputLine}" | cut -d ' ' -f "14")"
				scrubDay="$(echo "${statusOutputLine}" | cut -d ' ' -f "15")"
				scrubTime="$(echo "${statusOutputLine}" | cut -d ' ' -f "16")"

				scrubDuration="$(echo "${statusOutputLine}" | cut -d ' ' -f "6-8")"
				scrubErrors="$(echo "${statusOutputLine}" | cut -d ' ' -f "10")"
			else
				# We should test the version of zfs because there still is no json output
				scrubYear="$(echo "${statusOutputLine}" | cut -d ' ' -f "15")"
				scrubMonth="$(echo "${statusOutputLine}" | cut -d ' ' -f "12")"
				scrubDay="$(echo "${statusOutputLine}" | cut -d ' ' -f "13")"
				scrubTime="$(echo "${statusOutputLine}" | cut -d ' ' -f "14")"

				scrubDuration="$(echo "${statusOutputLine}" | cut -d ' ' -f "6")"
				scrubErrors="$(echo "${statusOutputLine}" | cut -d ' ' -f "8")"
			fi
			scrubDate="${scrubMonth} ${scrubDay} ${scrubYear} ${scrubTime}"


			if [ "${systemType}" = "BSD" ]; then
				scrubTS="$(date -j -f '%b %e %Y %H:%M:%S' "${scrubDate}" '+%s')"
			else
				scrubTS="$(date -d "${scrubDate}" '+%s')"
			fi
			currentTS="${runDate}"
			scrubAge="$((((currentTS - scrubTS) + 43200) / 86400))"
			}

		# if status is resilvered
		elif [ "$(echo "${statusOutputLine}" | cut -d ' ' -f "2")" = "resilvered" ]; then
			{
			resilver="<BR>Resilvered"
			multiDay="$(echo "${statusOutput}" | grep "scan" | grep -c "days")"
			scrubRepBytes="$(echo "${statusOutputLine}" | cut -d ' ' -f "3")"

			# Convert time/datestamp format presented by zpool status, compare to current date, calculate scrub age
			if [ "${multiDay}" -ge "1" ] ; then
				# We should test the version of zfs because there still is no json output
				scrubYear="$(echo "${statusOutputLine}" | cut -d ' ' -f "16")"
				scrubMonth="$(echo "${statusOutputLine}" | cut -d ' ' -f "13")"
				scrubDay="$(echo "${statusOutputLine}" | cut -d ' ' -f "14")"
				scrubTime="$(echo "${statusOutputLine}" | cut -d ' ' -f "15")"

				scrubDuration="$(echo "${statusOutputLine}" | cut -d ' ' -f "5-7")"
				scrubErrors="$(echo "${statusOutputLine}" | cut -d ' ' -f "9")"
			else
				# We should test the version of zfs because there still is no json output
				scrubYear="$(echo "${statusOutputLine}" | cut -d ' ' -f "14")"
				scrubMonth="$(echo "${statusOutputLine}" | cut -d ' ' -f "11")"
				scrubDay="$(echo "${statusOutputLine}" | cut -d ' ' -f "12")"
				scrubTime="$(echo "${statusOutputLine}" | cut -d ' ' -f "13")"

				scrubDuration="$(echo "${statusOutputLine}" | cut -d ' ' -f "5")"
				scrubErrors="$(echo "${statusOutputLine}" | cut -d ' ' -f "7")"
			fi
			scrubDate="${scrubMonth} ${scrubDay} ${scrubYear} ${scrubTime}"


			if [ "${systemType}" = "BSD" ]; then
				scrubTS="$(date -j -f '%b %e %Y %H:%M:%S' "${scrubDate}" '+%s')"
			else
				scrubTS="$(date -d "${scrubDate}" '+%s')"
			fi
			currentTS="${runDate}"
			scrubAge="$((((currentTS - scrubTS) + 43200) / 86400))"
			}

		# Check if resilver is in progress
		elif [ "$(echo "${statusOutputLine}" | cut -d ' ' -f "2")" = "resilver" ]; then
			{
			scrubRepBytes="Resilver In Progress"
			statusOutputLine="$(echo "${statusOutput}" | grep "resilvered," | sed -e 's:[[:blank:]]\{1,\}: :g' -e 's:^[[:blank:]]*::')"

			scrubAge="$(echo "${statusOutputLine}" | cut -d ' ' -f "3") done"
			scrubDuration="$(echo "${statusOutputLine}" | cut -d ' ' -f "5") <br> to go"
			}

		# Check if scrub is in progress
		elif [ "$(echo "${statusOutputLine}" | cut -d ' ' -f "4")" = "progress" ]; then
			{
			scrubRepBytes="Scrub In Progress"
			statusOutputLine="$(echo "${statusOutput}" | grep "repaired," | sed -e 's:[[:blank:]]\{1,\}: :g' -e 's:^[[:blank:]]*::')"

			scrubErrors="$(echo "${statusOutputLine}" | cut -d ' ' -f "1") repaired"
			scrubAge="$(echo "${statusOutputLine}" | cut -d ' ' -f "3") done"

			if [ "$(echo "${statusOutputLine}" | cut -d ' ' -f "5")" = "0" ]; then
				scrubDuration="$(echo "${statusOutputLine}" | cut -d ' ' -f "7") <br> to go"
			elif [ "$(echo "${statusOutputLine}" | cut -d ' ' -f "5")" = "no" ]; then
				scrubDuration="Calculating"
			elif [ "$(echo "${statusOutputLine}" | cut -d ' ' -f "6")" = "days" ]; then
				scrubDuration="$(echo "${statusOutputLine}" | cut -d ' ' -f "5") <br> days to go"
			else
				scrubDuration="$(echo "${statusOutputLine}" | cut -d ' ' -f "5") <br> to go"
			fi
			}
		fi

		{
		# Set the row background color
		if [ "${altRow}" = "false" ]; then
			local bgColor="#ffffff"
			altRow="true"
		else
			local bgColor="${altColor}"
			altRow="false"
		fi

		# Set up conditions for warning or critical colors to be used in place of standard background colors
		if [ ! "${status}" = "ONLINE" ]; then
			statusColor="${warnColor}"
		else
			statusColor="${bgColor}"
		fi
		status+="${resilver}"

		if [ ! "${readErrors}" = "0" ]; then
			readErrorsColor="${warnColor}"
		else
			readErrorsColor="${bgColor}"
		fi

		if [ ! "${writeErrors}" = "0" ]; then
			writeErrorsColor="${warnColor}"
		else
			writeErrorsColor="${bgColor}"
		fi

		if [ ! "${cksumErrors}" = "0" ]; then
			cksumErrorsColor="${warnColor}"
		else
			cksumErrorsColor="${bgColor}"
		fi

		if [ "${used}" -gt "${usedWarn}" ]; then
			usedColor="${warnColor}"
		else
			usedColor="${bgColor}"
		fi

		if [ ! "${scrubRepBytes}" = "N/A" ] && [ ! "${scrubRepBytes}" = "0" ] && [ ! "${scrubRepBytes}" = "0B" ]; then
			scrubRepBytesColor="${warnColor}"
		else
			scrubRepBytesColor="${bgColor}"
		fi

		if [ ! "${scrubErrors}" = "N/A" ] && [ ! "${scrubErrors}" = "0" ]; then
			scrubErrorsColor="${warnColor}"
		else
			scrubErrorsColor="${bgColor}"
		fi

		if [ "$(bc <<< "scale=0;($(echo "${scrubAge}" | sed -e 's:% done$::')+0)/1")" -gt "${scrubAgeWarn}" ]; then
			scrubAgeColor="${warnColor}"
		else
			scrubAgeColor="${bgColor}"
		fi
		}

		{
			# Use the information gathered above to write the date to the current table row
			tee <<- EOF
				<tr style="background-color:${bgColor}">
				<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${pool}</td>
				<td style="text-align:center; background-color:${statusColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${status}</td>
				<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${size}</td>
				<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${allocated}</td>
				<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${free}</td>
				<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${frag}%</td>
				<td style="text-align:center; background-color:${usedColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${used}%</td>
				<td style="text-align:center; background-color:${readErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${readErrors}</td>
				<td style="text-align:center; background-color:${writeErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${writeErrors}</td>
				<td style="text-align:center; background-color:${cksumErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${cksumErrors}</td>
				<td style="text-align:center; background-color:${scrubRepBytesColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${scrubRepBytes}</td>
				<td style="text-align:center; background-color:${scrubErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${scrubErrors}</td>
				<td style="text-align:center; background-color:${scrubAgeColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${scrubAge}</td>
				<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${scrubDuration}</td>
				</tr>
EOF
		} >> "${logfile}"
	done

	# End of zpool status table
	echo '</table>' >> "${logfile}"
}

# shellcheck disable=SC2155
function NVMeSummary () {

	###### NVMe SMART status summary table
	{
		# Write HTML table headers to log file
		tee <<- EOF
			<br><br>
			<table style="border: 1px solid black; border-collapse: collapse;">
			<tr><th colspan="18" style="text-align:center; font-size:20px; height:40px; font-family:courier;">NVMe SMART Status Report Summary</th></tr>
			<tr>

			  <th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Device</th> <!-- Device -->

			  <th style="text-align:center; width:140px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Model</th> <!-- Model -->

			  <th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Serial<br>Number</th> <!-- Serial Number -->

			  <th style="text-align:center; width:90px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Capacity</th> <!-- Capacity -->

			  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">SMART<br>Status</th> <!-- SMART Status -->

			  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Temp</th> <!-- Temp -->

			  <th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power-On<br>Time<br>($powerTimeFormat)</th> <!-- Power-On Time -->

			  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power<br>Cycle<br>Count</th> <!-- Power Cycle Count -->

			  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Integrity<br>Errors</th> <!-- Integrity Errors -->

			  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Error<br>Log<br>Entries</th> <!-- Error Log Entries -->

			  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Critical<br>Warning</th> <!-- Critical Warning -->

			  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Wear<br>Leveling<br>Count</th> <!-- Wear Leveling Count -->

			  <th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Total<br>Bytes<br>Written</th> <!-- Total Bytes Written -->

			  <th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Bytes Written<br>(per Day)</th> <!-- Bytes Written (per Day) -->

			  <th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Age (days)</th> <!-- Last Test Age (days) -->

			  <th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Type</th></tr> <!-- Last Test Type -->

			</tr>
EOF
	} >> "${logfile}"


	local drive
	local altRow="false"
	for drive in "${drives[@]}"; do
		if echo "${drive}" | grep -q "nvme"; then
			# For each drive detected, run "smartctl -AHij" and parse its output.
			# Start by parsing variables used in other parts of the script.
			# After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
			# After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
			# Finally, print the HTML code for the current row of the table with all the gathered data.

			# Get drive attributes
			local nvmeSmarOut="$(smartctl -AHij "/dev/${drive}")"

			local model="$(echo "${nvmeSmarOut}" | jq -Mre '.model_name | values')"
			local serial="$(echo "${nvmeSmarOut}" | jq -Mre '.serial_number | values')"
			local temp="$(echo "${nvmeSmarOut}" | jq -Mre '.temperature.current | values')"
			local onHours="$(echo "${nvmeSmarOut}" | jq -Mre '.power_on_time.hours | values')"
			local startStop="$(echo "${nvmeSmarOut}" | jq -Mre '.power_cycle_count | values')"
			local sectorSize="$(echo "${nvmeSmarOut}" | jq -Mre '.logical_block_size | values')"

			local mediaErrors="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.media_errors | values')"
			local errorsLogs="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.num_err_log_entries | values')"
			local critWarning="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.critical_warning | values')"
			local wearLeveling="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.available_spare | values')"
			local totalLBA="$(echo "${nvmeSmarOut}" | jq -Mre '.nvme_smart_health_information_log.data_units_written | values')"

			if [ "$(echo "${nvmeSmarOut}" | jq -Mre '.smart_status.passed | values')" = "true" ]; then
				local smartStatus="PASSED"
			else
				local smartStatus="FAILED"
			fi


			## Make override adjustments
			{
			local serialClean
			local serialMatch

			serialClean="$(sed -e 's:-:_:' <<< "${serial}")"

			# onHours
			serialMatch="_${serialClean}[onHours]"
			if [ ! -z "${!serialMatch}" ]; then
				onHours="$(bc <<< "${onHours} ${!serialMatch}")"
			fi

			# mediaErrors
			serialMatch="_${serialClean}[mediaErrors]"
			if [ ! -z "${!serialMatch}" ]; then
				mediaErrors="$(bc <<< "${mediaErrors} ${!serialMatch}")"
			fi

			# errorsLogs
			serialMatch="_${serialClean}[errorsLogs]"
			if [ ! -z "${!serialMatch}" ]; then
				errorsLogs="$(bc <<< "${errorsLogs} ${!serialMatch}")"
			fi

			# critWarning
			serialMatch="_${serialClean}[critWarning]"
			if [ ! -z "${!serialMatch}" ]; then
				critWarning="$(bc <<< "${critWarning} ${!serialMatch}")"
			fi

			# wearLeveling
			serialMatch="_${serialClean}[wearLeveling]"
			if [ ! -z "${!serialMatch}" ]; then
				wearLeveling="$(bc <<< "${wearLeveling} ${!serialMatch}")"
			fi
			}


			## Formatting
			# Calculate capacity for user consumption
			local capacityByte="$(echo "${nvmeSmarOut}" | jq -Mre '.user_capacity.bytes | values')"
			: "${capacityByte:="0"}"

			if [ "${#capacityByte}" -gt "12" ]; then
				local capacitySufx=" TB"
				local capacityExp="12"
			elif [ "${#capacityByte}" -gt "9" ]; then
				local capacitySufx=" GB"
				local capacityExp="9"
			else
				local capacitySufx=""
				local capacityExp="1"
			fi

			local capacityPre="$(bc <<< "scale=2; ${capacityByte} / (10^${capacityExp})" | head -c 4 | sed -e 's:\.$::')"
			local capacity="[${capacityPre}${capacitySufx}]"

			# Get more useful times from hours
			local testAge="$(bc <<< "(${onHours} - (${onHours} - 2) ) / 24")" # ${lastTestHours}
			local yrs="$(bc <<< "${onHours} / 8760")"
			local mos="$(bc <<< "(${onHours} % 8760) / 730")"
			local dys="$(bc <<< "((${onHours} % 8760) % 730) / 24")"
			local hrs="$(bc <<< "((${onHours} % 8760) % 730) % 24")"

			# Set Power-On Time format
			if [ "${powerTimeFormat}" = "ymdh" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			elif [ "${powerTimeFormat}" = "ymd" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d"
			elif [ "${powerTimeFormat}" = "ym" ]; then
				local onTime="${yrs}y ${mos}m"
			elif [ "${powerTimeFormat}" = "y" ]; then
				local onTime="${yrs}y"
			else
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			fi

			# Set the row background color
			if [ "${altRow}" = "false" ]; then
				local bgColor="#ffffff"
				altRow="true"
			else
				local bgColor="${altColor}"
				altRow="false"
			fi

			# Colorize smart status
			if [ ! "${smartStatus}" = "PASSED" ]; then
				local smartStatusColor="${critColor}"
			else
				local smartStatusColor="${okColor}"
			fi

			# Colorize temp
			if [ "${temp:="0"}" -ge "${ssdTempCrit}" ]; then
				local tempColor="${critColor}"
			elif [ "${temp:="0"}" -ge "${ssdTempWarn}" ]; then
				local tempColor="${warnColor}"
			else
				local tempColor="${bgColor}"
			fi
			if [ "${temp}" = "0" ]; then
				local temp="N/A"
			else
				local temp="${temp}&deg;C"
			fi

			# Colorize log errors
			if [ "${errorsLogs:-"0"}" -gt "${sectorsCrit}" ]; then
				local errorsLogsColor="${critColor}"
			elif [ ! "${errorsLogs}" = "0" ]; then
				local errorsLogsColor="${warnColor}"
			else
				local errorsLogsColor="${bgColor}"
			fi

			# Colorize warnings
			if [ "${critWarning:-"0"}" -gt "${sectorsCrit}" ]; then
				local critWarningColor="${critColor}"
			elif [ ! "${critWarning}" = "0" ]; then
				local critWarningColor="${warnColor}"
			else
				local critWarningColor="${bgColor}"
			fi

			# Colorize Media Errors
			if [ ! "${mediaErrors}" = "0" ]; then
				local mediaErrorsColor="${warnColor}"
			else
				local mediaErrorsColor="${bgColor}"
			fi

			# Colorize Wear Leveling
			if [ -z "${wearLeveling}" ]; then
				wearLeveling="N/A"
				local wearLevelingColor="${bgColor}"
			elif [ "${wearLeveling}" -le "${lifeRemainCrit}" ]; then
				local wearLevelingColor="${critColor}"
			elif [ "${wearLeveling}" -le "${lifeRemainWarn}" ]; then
				local wearLevelingColor="${warnColor}"
			else
				local wearLevelingColor="${bgColor}"
			fi

			# Colorize & derive write stats
			# 512 because apparently the NVMe spec uses magic numbers
			local totalBW="$(bc <<< "scale=1; (${totalLBA} * 512) / (1000^3)" | sed -e 's:^\.:0.:')"
			if (( $(bc -l <<< "${totalBW} > ${totalBWCrit}") )); then
				local totalBWColor="${critColor}"
			elif (( $(bc -l <<< "${totalBW} > ${totalBWWarn}") )); then
				local totalBWColor="${warnColor}"
			else
				local totalBWColor="${bgColor}"
			fi
			if [ "${totalBW}" = "0.0" ]; then
				totalBW="N/A"
			else
				totalBW="${totalBW}TB"
			fi
			# Try to not divide by zero
			# 512 because apparently the NVMe spec uses magic numbers
			if [ ! "0" = "$(bc <<< "scale=1; ${onHours} / 24")" ]; then
				local bwPerDay="$(bc <<< "scale=1; (((${totalLBA} * 512) / (1000^3)) * 1000) / (${onHours} / 24)" | sed -e 's:^\.:0.:')"
				if [ "${bwPerDay}" = "0.0" ]; then
					bwPerDay="N/A"
				else
					bwPerDay="${bwPerDay}GB"
				fi
			else
				local bwPerDay="N/A"
			fi

			# Colorize test age
			if [ "${testAge:-"0"}" -gt "${testAgeWarn}" ]; then
				local testAgeColor="${critColor}"
			else
				local testAgeColor="${bgColor}"
			fi


			{
				# Output the row
				tee <<- EOF
					<tr style="background-color:${bgColor};">
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">/dev/${drive}</td> <!-- device -->
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${model}</td> <!-- model -->
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${serial}</td> <!-- serial -->
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${capacity}</td> <!-- capacity -->
					<td style="text-align:center; background-color:${smartStatusColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${smartStatus}</td> <!-- smartStatusColor, smartStatus -->
					<td style="text-align:center; background-color:${tempColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${temp}</td> <!-- tempColor, temp -->
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${onTime}</td> <!-- onTime -->
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${startStop}</td> <!-- startStop -->
					<td style="text-align:center; background-color:${mediaErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${mediaErrors}</td> <!-- mediaErrorsColor, mediaErrors -->
					<td style="text-align:center; background-color:${errorsLogsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${errorsLogs}</td> <!-- errorsLogsColor, errorsLogs -->
					<td style="text-align:center; background-color:${critWarningColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${critWarning}</td> <!-- critWarningColor, critWarning -->
					<td style="text-align:center; background-color:${wearLevelingColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${wearLeveling}</td> <!-- wearLevelingColor, wearLeveling -->
					<td style="text-align:center; background-color:${totalBWColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${totalBW}</td> <!-- totalBWColor, totalBW -->
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${bwPerDay}</td> <!-- bwPerDay -->
					<td style="text-align:center; background-color:${testAgeColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">N/A</td> <!-- testAgeColor, testAge -->
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">N/A</td> <!-- lastTestType -->
					</tr>
EOF
			} >> "${logfile}"
		fi
	done

	# End SMART summary table section
	{
		echo "</table>"
	} >> "${logfile}"
}

# shellcheck disable=SC2155
function SSDSummary () {
	###### SSD SMART status summary table
	{
		# Write HTML table headers to log file
		tee <<- EOF
			<br><br>
			<table style="border: 1px solid black; border-collapse: collapse;">
			<tr><th colspan="18" style="text-align:center; font-size:20px; height:40px; font-family:courier;">SSD SMART Status Report Summary</th></tr>
			<tr>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Device</th>
			<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Model</th>
			<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Serial<br>Number</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Capacity</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">SMART<br>Status</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Temp</th>
			<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power-On<br>Time<br>(${powerTimeFormat})</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power<br>Cycle<br>Count</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Realloc<br>Sectors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Program<br>Fail<br>Count</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Erase<br>Fail<br>Count</th>
			<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Offline<br>Uncorrectable<br>Sectors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">CRC<br>Errors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Wear<br>Leveling<br>Count</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Total<br>Bytes<br>Written</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Bytes Written<br>(per Day)</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Age (days)</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Type</th></tr>
			</tr>
EOF
	} >> "${logfile}"

	local drive
	local altRow="false"
	for drive in "${drives[@]}"; do
		local ssdInfoSmrt="$(smartctl -AHijl xselftest,selftest --log="devstat" "/dev/${drive}")"
		local rotTst="$(echo "${ssdInfoSmrt}" | jq -Mre '.rotation_rate | values')"
		local scsiTst="$(echo "${ssdInfoSmrt}" | jq -Mre '.device.type | values')"
		if [ "${rotTst}" = "0" ] && [ ! "${scsiTst}" = "scsi" ]; then
			# For each drive detected, run "smartctl -AHijl xselftest,selftest" and parse its output.
			# Start by parsing out the variables used in other parts of the script.
			# After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
			# After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
			# Finally, print the HTML code for the current row of the table with all the gathered data.
			local device="${drive}"

			# Available if any tests have completed
			if [ ! -z "$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table | values')" ]; then
				local lastTestHours="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].lifetime_hours | values')"
				local lastTestType="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].type.string | values')"
				local lastTestStatus="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].status.passed | values')"
			else
				local lastTestHours="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].lifetime_hours | values')"
				local lastTestType="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].type.string | values')"
				local lastTestStatus="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].status.passed | values')"
			fi

			# Available for any drive smartd knows about
			if [ "$(echo "${ssdInfoSmrt}" | jq -Mre '.smart_status.passed | values')" = "true" ]; then
				local smartStatus="PASSED"
			else
				local smartStatus="FAILED"
			fi

			local model="$(echo "${ssdInfoSmrt}" | jq -Mre '.model_name | values')"
			local serial="$(echo "${ssdInfoSmrt}" | jq -Mre '.serial_number | values')"
			local temp="$(echo "${ssdInfoSmrt}" | jq -Mre '.temperature.current | values')"
			local onHours="$(echo "${ssdInfoSmrt}" | jq -Mre '.power_on_time.hours | values')"
			local startStop="$(echo "${ssdInfoSmrt}" | jq -Mre '.power_cycle_count | values')"
			local sectorSize="$(echo "${ssdInfoSmrt}" | jq -Mre '.logical_block_size | values')"

			# Available for most common drives
			local reAlloc="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 5) | .raw.value | values')"
			local progFail="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 171) | .raw.value | values')"
			local eraseFail="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 172) | .raw.value | values')"
			local offlineUnc="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 187) | .raw.value | values')"
			local crcErrors="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 199) | .raw.value | values')"

			# No standard attribute for % ssd life remanining
			local wearLeveling="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 173) | .value | values')"
			if [ -z "${wearLeveling}" ]; then
				wearLeveling="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 231) | .value | values')"
				if [ -z "${wearLeveling}" ]; then
					wearLeveling="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 233) | .value | values')"
					if [ -z "${wearLeveling}" ]; then
						wearLeveling="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 177) | .value | values')"
					fi
				fi
			fi

			# Get LBA written from the stats page for data written
			if [ ! -z "$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_device_statistics.pages[0] | values')" ]; then
				local totalLBA="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_device_statistics.pages[0].table[] | select(.name == "Logical Sectors Written") | .value | values')"
			elif [ "$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 175) | .name | values')" = "Host_Writes_MiB" ]; then
				# Fallback for apple SSDs that do not have a stats page
				local totalLBA="$(bc <<< "($(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 175) | .raw.value | values') * (1024^2) / ${sectorSize})")"
			elif [ "$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 241) | .name | values')" = "Total_LBAs_Written" ]; then
				# Fallback for seagate SSDs that do not have a stats page
				local totalLBA="$(echo "${ssdInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 241)')"
			else
				local totalLBA="0"
			fi


			## Make override adjustments
			{
			local serialClean
			local serialMatch

			serialClean="$(sed -e 's:-:_:' <<< "${serial}")"

			# lastTestHours
			serialMatch="_${serialClean}[lastTestHours]"
			if [ ! -z "${!serialMatch}" ]; then
				lastTestHours="$(bc <<< "${lastTestHours} ${!serialMatch}")"
			fi

			# onHours
			serialMatch="_${serialClean}[onHours]"
			if [ ! -z "${!serialMatch}" ]; then
				onHours="$(bc <<< "${onHours} ${!serialMatch}")"
			fi

			# reAlloc
			serialMatch="_${serialClean}[reAlloc]"
			if [ ! -z "${!serialMatch}" ]; then
				reAlloc="$(bc <<< "${reAlloc} ${!serialMatch}")"
			fi

			# progFail
			serialMatch="_${serialClean}[progFail]"
			if [ ! -z "${!serialMatch}" ]; then
				progFail="$(bc <<< "${progFail} ${!serialMatch}")"
			fi

			# eraseFail
			serialMatch="_${serialClean}[eraseFail]"
			if [ ! -z "${!serialMatch}" ]; then
				eraseFail="$(bc <<< "${eraseFail} ${!serialMatch}")"
			fi

			# offlineUnc
			serialMatch="_${serialClean}[offlineUnc]"
			if [ ! -z "${!serialMatch}" ]; then
				offlineUnc="$(bc <<< "${offlineUnc} ${!serialMatch}")"
			fi

			# crcErrors
			serialMatch="_${serialClean}[crcErrors]"
			if [ ! -z "${!serialMatch}" ]; then
				crcErrors="$(bc <<< "${crcErrors} ${!serialMatch}")"
			fi

			# wearLeveling
			serialMatch="_${serialClean}[wearLeveling]"
			if [ ! -z "${!serialMatch}" ]; then
				wearLeveling="$(bc <<< "${wearLeveling} ${!serialMatch}")"
			fi
			}


			## Formatting
			# Calculate capacity for user consumption
			local capacityByte="$(echo "${ssdInfoSmrt}" | jq -Mre '.user_capacity.bytes | values')"
			: "${capacityByte:="0"}"

			if [ "${#capacityByte}" -gt "12" ]; then
				local capacitySufx=" TB"
				local capacityExp="12"
			elif [ "${#capacityByte}" -gt "9" ]; then
				local capacitySufx=" GB"
				local capacityExp="9"
			else
				local capacitySufx=""
				local capacityExp="1"
			fi

			local capacityPre="$(bc <<< "scale=2; ${capacityByte} / (10^${capacityExp})" | head -c 4 | sed -e 's:\.$::')"
			local capacity="[${capacityPre}${capacitySufx}]"

			# Get more useful times from hours
			local testAge=""
			if [ ! -z "${lastTestHours}" ]; then
				# Check whether the selftest log times have overflowed after 65,535 hours of total power-on time
				overflowTest="$((onHours - lastTestHours))"
				if [ "${overflowTest}" -gt "65535" ]; then # Correct the overflow if necessary
					testAge="$(bc <<< "(${onHours} - ${lastTestHours} - 65535) / 24")"
				else # Normal Case, no overflow
					testAge="$(bc <<< "(${onHours} - ${lastTestHours}) / 24")"
				fi
			fi

			local yrs="$(bc <<< "${onHours} / 8760")"
			local mos="$(bc <<< "(${onHours} % 8760) / 730")"
			local dys="$(bc <<< "((${onHours} % 8760) % 730) / 24")"
			local hrs="$(bc <<< "((${onHours} % 8760) % 730) % 24")"

			# Set Power-On Time format
			if [ "${powerTimeFormat}" = "ymdh" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			elif [ "${powerTimeFormat}" = "ymd" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d"
			elif [ "${powerTimeFormat}" = "ym" ]; then
				local onTime="${yrs}y ${mos}m"
			elif [ "${powerTimeFormat}" = "y" ]; then
				local onTime="${yrs}y"
			else
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			fi

			# Set the row background color
			if [ "${altRow}" = "false" ]; then
				local bgColor="#ffffff"
				altRow="true"
			else
				local bgColor="${altColor}"
				altRow="false"
			fi

			# Colorize Smart Status
			if [ ! "${smartStatus}" = "PASSED" ]; then
				local smartStatusColor="${critColor}"
			else
				local smartStatusColor="${okColor}"
			fi

			# Colorize Smart test Status
			if [ "${lastTestStatus}" = "false" ]; then
				local lastTestStatusColor="${critColor}"
			else
				local lastTestStatusColor="${bgColor}"
			fi

			# Colorize Temp
			if [ "${temp:="0"}" -ge "${ssdTempCrit}" ]; then
				local tempColor="${critColor}"
			elif [ "${temp:="0"}" -ge "${ssdTempWarn}" ]; then
				local tempColor="${warnColor}"
			else
				local tempColor="${bgColor}"
			fi
			if [ "${temp}" = "0" ]; then
				local temp="N/A"
			else
				local temp="${temp}&deg;C"
			fi

			# Colorize Sector Errors
			if [ "${reAlloc:-"0"}" -gt "${sectorsCrit}" ]; then
				local reAllocColor="${critColor}"
			elif [ ! "${reAlloc}" = "0" ] && [ ! -z "${reAlloc}" ]; then
				local reAllocColor="${warnColor}"
			else
				local reAllocColor="${bgColor}"
			fi

			# Colorize Program Fail
			if [ "${progFail:-"0"}" -gt "${sectorsCrit}" ]; then
				local progFailColor="${critColor}"
			elif [ ! "${progFail}" = "0" ] && [ ! -z "${progFail}" ]; then
				local progFailColor="${warnColor}"
			else
				local progFailColor="${bgColor}"
			fi

			# Colorize Erase Fail
			if [ "${eraseFail:-"0"}" -gt "${sectorsCrit}" ]; then
				local eraseFailColor="${critColor}"
			elif [ ! "${eraseFail}" = "0" ] && [ ! -z "${eraseFail}" ]; then
				local eraseFailColor="${warnColor}"
			else
				local eraseFailColor="${bgColor}"
			fi

			# Colorize Offline Uncorrectable
			if [ "${offlineUnc:-"0"}" -gt "${sectorsCrit}" ]; then
				local offlineUncColor="${critColor}"
			elif [ ! "${offlineUnc}" = "0" ] && [ ! -z "${offlineUnc}" ]; then
				local offlineUncColor="${warnColor}"
			else
				local offlineUncColor="${bgColor}"
			fi

			# Colorize CRC Errors
			if [ ! "${crcErrors:-"0"}" = "0" ]; then
				local crcErrorsColor="${warnColor}"
			else
				local crcErrorsColor="${bgColor}"
			fi

			# Colorize Wear Leveling
			if [ ! -z "${wearLeveling}" ]; then
				if [ "${wearLeveling}" -le "${lifeRemainCrit}" ]; then
					local wearLevelingColor="${critColor}"
				elif [ "${wearLeveling}" -le "${lifeRemainWarn}" ]; then
					local wearLevelingColor="${warnColor}"
				else
					local wearLevelingColor="${bgColor}"
				fi
			fi

			# Colorize & derive write stats
			local totalBW="$(bc <<< "scale=1; (${totalLBA} * ${sectorSize}) / (1000^4)" | sed -e 's:^\.:0.:')"
			if (( $(bc -l <<< "${totalBW} > ${totalBWCrit}") )); then
				local totalBWColor="${critColor}"
			elif (( $(bc -l <<< "${totalBW} > ${totalBWWarn}") )); then
				local totalBWColor="${warnColor}"
			else
				local totalBWColor="${bgColor}"
			fi
			if [ "${totalBW}" = "0.0" ]; then
				totalBW="N/A"
			else
				totalBW="${totalBW}TB"
			fi
			# Try to not divide by zero
			if [ ! "0" = "$(bc <<< "scale=1; ${onHours} / 24")" ]; then
				local bwPerDay="$(bc <<< "scale=1; (((${totalLBA} * ${sectorSize}) / (1000^4)) * 1000) / (${onHours} / 24)" | sed -e 's:^\.:0.:')"
				if [ "${bwPerDay}" = "0.0" ]; then
					bwPerDay="N/A"
				else
					bwPerDay="${bwPerDay}GB"
				fi
			else
				local bwPerDay="N/A"
			fi

			# Colorize test age
			if [ "${testAge:-"0"}" -gt "${testAgeWarn}" ]; then
				local testAgeColor="${critColor}"
			else
				local testAgeColor="${bgColor}"
			fi


			{
				# Row Output
				tee <<- EOF
					<tr style="background-color:${bgColor};">
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">/dev/${device}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${model}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${serial}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${capacity}</td>
					<td style="text-align:center; background-color:${smartStatusColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${smartStatus}</td>
					<td style="text-align:center; background-color:${tempColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${temp}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${onTime}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${startStop}</td>
					<td style="text-align:center; background-color:${reAllocColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${reAlloc:-N/A}</td>
					<td style="text-align:center; background-color:${progFailColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${progFail:-N/A}</td>
					<td style="text-align:center; background-color:${eraseFailColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${eraseFail:-N/A}</td>
					<td style="text-align:center; background-color:${offlineUncColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${offlineUnc:-N/A}</td>
					<td style="text-align:center; background-color:${crcErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${crcErrors:-N/A}</td>
					<td style="text-align:center; background-color:${wearLevelingColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${wearLeveling:-N/A}%</td>
					<td style="text-align:center; background-color:${totalBWColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${totalBW}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${bwPerDay}</td>
					<td style="text-align:center; background-color:${testAgeColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${testAge:-"N/A"}</td>
					<td style="text-align:center; background-color:${lastTestStatusColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${lastTestType:-"N/A"}</td>
					</tr>
EOF
			} >> "${logfile}"
		fi
	done

	# End SSD SMART summary table
	{
		echo '</table>'
	} >> "${logfile}"
}

# shellcheck disable=SC2155
function HDDSummary () {
	###### HDD SMART status summary table
	{
		# Write HTML table headers to log file
		tee <<- EOF
			<br><br>
			<table style="border: 1px solid black; border-collapse: collapse;">
			<tr><th colspan="18" style="text-align:center; font-size:20px; height:40px; font-family:courier;">HDD SMART Status Report Summary</th></tr>
			<tr>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Device</th>
			<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Model</th>
			<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Serial<br>Number</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">RPM</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Capacity</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">SMART<br>Status</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Temp</th>
			<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power-On<br>Time<br>(${powerTimeFormat})</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Start<br>Stop<br>Count</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Spin<br>Retry<br>Count</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Realloc<br>Sectors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Realloc<br>Events</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Current<br>Pending<br>Sectors</th>
			<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Offline<br>Uncorrectable<br>Sectors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">CRC<br>Errors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Seek<br>Error<br>Health</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Age (days)</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Type</th></tr>
			</tr>
EOF
	} >> "${logfile}"

	local drive
	local altRow="false"
	for drive in "${drives[@]}"; do
		local hddInfoSmrt="$(smartctl -AHijl xselftest,selftest "/dev/${drive}")"
		local rotTst="$(echo "${hddInfoSmrt}" | jq -Mre '.rotation_rate | values')"
		local scsiTst="$(echo "${hddInfoSmrt}" | jq -Mre '.device.type | values')"
		if [ -z "${rotTst}" ] && [ ! -z "$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[]? | select(.name == "Spin_Up_Time") | .id | values')" ]; then
			rotTst="N/R"
		fi
		if [ ! "${rotTst:-"0"}" = "0" ] && [ ! "${scsiTst}" = "scsi" ]; then
			# For each drive detected, run "smartctl -AHijl xselftest,selftest" and parse its output.
			# After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
			# After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
			# Finally, print the HTML code for the current row of the table with all the gathered data.

			local device="${drive}"

			# Available if any tests have completed
			if [ ! -z "$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table | values')" ]; then
				local lastTestHours="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].lifetime_hours | values')"
				local lastTestType="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].type.string | values')"
				local lastTestStatus="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].status.passed | values')"
			else
				local lastTestHours="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].lifetime_hours | values')"
				local lastTestType="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].type.string | values')"
				local lastTestStatus="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].status.passed | values')"
			fi

			# Available for any drive smartd knows about
			if [ "$(echo "${hddInfoSmrt}" | jq -Mre '.smart_status.passed | values')" = "true" ]; then
				local smartStatus="PASSED"
			else
				local smartStatus="FAILED"
			fi

			local model="$(echo "${hddInfoSmrt}" | jq -Mre '.model_name | values')"
			local serial="$(echo "${hddInfoSmrt}" | jq -Mre '.serial_number | values')"
			local rpm="$(echo "${hddInfoSmrt}" | jq -Mre '.rotation_rate | values')"
			local temp="$(echo "${hddInfoSmrt}"| jq -Mre '.temperature.current | values')"
			local onHours="$(echo "${hddInfoSmrt}" | jq -Mre '.power_on_time.hours | values')"
			local startStop="$(echo "${hddInfoSmrt}" | jq -Mre '.power_cycle_count | values')"

			# Available for most common drives
			local reAlloc="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 5) | .raw.value | values')"
			local spinRetry="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 10) | .raw.value | values')"
			local reAllocEvent="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 196) | .raw.value | values')"
			local pending="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 197) | .raw.value | values')"
			local offlineUnc="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 198) | .raw.value | values')"
			local crcErrors="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 199) | .raw.value | values')"
			local seekErrorHealth="$(echo "${hddInfoSmrt}" | jq -Mre '.ata_smart_attributes.table[] | select(.id == 7) | .value | values')"


			## Make override adjustments
			{
			local serialClean
			local serialMatch

			serialClean="$(sed -e 's:-:_:' <<< "${serial}")"

			# lastTestHours
			serialMatch="_${serialClean}[lastTestHours]"
			if [ ! -z "${!serialMatch}" ]; then
				lastTestHours="$(bc <<< "${lastTestHours} ${!serialMatch}")"
			fi

			# onHours
			serialMatch="_${serialClean}[onHours]"
			if [ ! -z "${!serialMatch}" ]; then
				onHours="$(bc <<< "${onHours} ${!serialMatch}")"
			fi

			# reAlloc
			serialMatch="_${serialClean}[reAlloc]"
			if [ ! -z "${!serialMatch}" ]; then
				reAlloc="$(bc <<< "${reAlloc} ${!serialMatch}")"
			fi

			# spinRetry
			serialMatch="_${serialClean}[spinRetry]"
			if [ ! -z "${!serialMatch}" ]; then
				spinRetry="$(bc <<< "${spinRetry} ${!serialMatch}")"
			fi

			# reAllocEvent
			serialMatch="_${serialClean}[reAllocEvent]"
			if [ ! -z "${!serialMatch}" ]; then
				reAllocEvent="$(bc <<< "${reAllocEvent} ${!serialMatch}")"
			fi

			# pending
			serialMatch="_${serialClean}[pending]"
			if [ ! -z "${!serialMatch}" ]; then
				pending="$(bc <<< "${pending} ${!serialMatch}")"
			fi

			# offlineUnc
			serialMatch="_${serialClean}[offlineUnc]"
			if [ ! -z "${!serialMatch}" ]; then
				offlineUnc="$(bc <<< "${offlineUnc} ${!serialMatch}")"
			fi

			# crcErrors
			serialMatch="_${serialClean}[crcErrors]"
			if [ ! -z "${!serialMatch}" ]; then
				crcErrors="$(bc <<< "${crcErrors} ${!serialMatch}")"
			fi

			# seekErrorHealth
			serialMatch="_${serialClean}[seekErrorHealth]"
			if [ ! -z "${!serialMatch}" ]; then
				seekErrorHealth="$(bc <<< "${seekErrorHealth} ${!serialMatch}")"
			fi
			}


			## Formatting
			# Calculate capacity for user consumption
			local capacityByte="$(echo "${hddInfoSmrt}" | jq -Mre '.user_capacity.bytes | values')"
			: "${capacityByte:="0"}"

			if [ "${#capacityByte}" -gt "12" ]; then
				local capacitySufx=" TB"
				local capacityExp="12"
			elif [ "${#capacityByte}" -gt "9" ]; then
				local capacitySufx=" GB"
				local capacityExp="9"
			else
				local capacitySufx=""
				local capacityExp="1"
			fi

			local capacityPre="$(bc <<< "scale=2; ${capacityByte} / (10^${capacityExp})" | head -c 4 | sed -e 's:\.$::')"
			local capacity="[${capacityPre}${capacitySufx}]"

			# Get more useful times from hours
			local testAge=""
			if [ ! -z "${lastTestHours}" ]; then
				# Check whether the selftest log times have overflowed after 65,535 hours of total power-on time
				overflowTest="$((onHours - lastTestHours))"
				if [ "${overflowTest}" -gt "65535" ]; then # Correct the overflow if necessary
					testAge="$(bc <<< "(${onHours} - ${lastTestHours} - 65535) / 24")"
				else # Normal Case, no overflow
					testAge="$(bc <<< "(${onHours} - ${lastTestHours}) / 24")"
				fi
			fi

			local yrs="$(bc <<< "${onHours} / 8760")"
			local mos="$(bc <<< "(${onHours} % 8760) / 730")"
			local dys="$(bc <<< "((${onHours} % 8760) % 730) / 24")"
			local hrs="$(bc <<< "((${onHours} % 8760) % 730) % 24")"

			# Set Power-On Time format
			if [ "${powerTimeFormat}" = "ymdh" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			elif [ "${powerTimeFormat}" = "ymd" ]; then
				local onTime="${yrs}y ${mos}m ${dys}d"
			elif [ "${powerTimeFormat}" = "ym" ]; then
				local onTime="${yrs}y ${mos}m"
			elif [ "${powerTimeFormat}" = "y" ]; then
				local onTime="${yrs}y"
			else
				local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
			fi

			# Set the row background color
			if [ "${altRow}" = "false" ]; then
				local bgColor="#ffffff"
				altRow="true"
			else
				local bgColor="${altColor}"
				altRow="false"
			fi

			# Colorize Smart Status
			if [ ! "${smartStatus}" = "PASSED" ]; then
				local smartStatusColor="${critColor}"
			else
				local smartStatusColor="${okColor}"
			fi

			# Colorize Smart test Status
			if [ "${lastTestStatus}" = "false" ]; then
				local lastTestStatusColor="${critColor}"
			else
				local lastTestStatusColor="${bgColor}"
			fi

			# Colorize Temp
			if [ "${temp:="0"}" -ge "${tempCrit}" ]; then
				local tempColor="${critColor}"
			elif [ "${temp:="0"}" -ge "${tempWarn}" ]; then
				local tempColor="${warnColor}"
			else
				local tempColor="${bgColor}"
			fi
			if [ "${temp}" = "0" ]; then
				local temp="N/A"
			else
				local temp="${temp}&deg;C"
			fi

			# Colorize Spin Retry Errors
			if [ ! "${spinRetry:-"0"}" = "0" ]; then
				local spinRetryColor="${warnColor}"
			else
				local spinRetryColor="${bgColor}"
			fi

			# Colorize Sector Errors
			if [ "${reAlloc:-"0"}" -gt "${sectorsCrit}" ]; then
				local reAllocColor="${critColor}"
			elif [ ! "${reAlloc}" = "0" ]; then
				local reAllocColor="${warnColor}"
			else
				local reAllocColor="${bgColor}"
			fi

			# Colorize Sector Event Errors
			if [ ! "${reAllocEvent:-"0"}" = "0" ]; then
				local reAllocEventColor="${warnColor}"
			else
				local reAllocEventColor="${bgColor}"
			fi

			# Colorize Pending Sector
			if [ "${pending:-"0"}" -gt "${sectorsCrit}" ]; then
				local pendingColor="${critColor}"
			elif [ ! "${offlineUnc}" = "0" ]; then
				local pendingColor="${warnColor}"
			else
				local pendingColor="${bgColor}"
			fi

			# Colorize Offline Uncorrectable
			if [ "${offlineUnc:-"0"}" -gt "${sectorsCrit}" ]; then
				local offlineUncColor="${critColor}"
			elif [ ! "${offlineUnc}" = "0" ]; then
				local offlineUncColor="${warnColor}"
			else
				local offlineUncColor="${bgColor}"
			fi

			# Colorize CRC Errors
			if [ ! "${crcErrors:-"0"}" = "0" ]; then
				local crcErrorsColor="${warnColor}"
			else
				local crcErrorsColor="${bgColor}"
			fi

			# Colorize Seek Error
			if [ "${seekErrorHealth:-"0"}" -lt "100" ]; then
				local seekErrorHealthColor="${warnColor}"
			else
				local seekErrorHealthColor="${bgColor}"
			fi

			# Colorize test age
			if [ "${testAge:-"0"}" -gt "${testAgeWarn}" ]; then
				local testAgeColor="${critColor}"
			else
				local testAgeColor="${bgColor}"
			fi


			{
				# Row Output
				tee <<- EOF
					<tr style="background-color:${bgColor};">
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">/dev/${device}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${model}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${serial}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${rpm}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${capacity}</td>
					<td style="text-align:center; background-color:${smartStatusColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${smartStatus}</td>
					<td style="text-align:center; background-color:${tempColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${temp}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${onTime}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${startStop}</td>
					<td style="text-align:center; background-color:${spinRetryColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${spinRetry}</td>
					<td style="text-align:center; background-color:${reAllocColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${reAlloc}</td>
					<td style="text-align:center; background-color:${reAllocEventColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${reAllocEvent}</td>
					<td style="text-align:center; background-color:${pendingColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${pending}</td>
					<td style="text-align:center; background-color:${offlineUncColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${offlineUnc}</td>
					<td style="text-align:center; background-color:${crcErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${crcErrors}</td>
					<td style="text-align:center; background-color:${seekErrorHealthColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${seekErrorHealth}%</td>
					<td style="text-align:center; background-color:${testAgeColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${testAge:-"N/A"}</td>
					<td style="text-align:center; background-color:${lastTestStatusColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${lastTestType:-"N/A"}</td>
					</tr>
EOF
			} >> "${logfile}"
		fi
	done

	# End SMART summary table and summary section
	{
		echo '</table>'
		echo '<br><br>'
	} >> "${logfile}"
}

# shellcheck disable=SC2155
function SASSummary () {
	###### SAS SMART status summary table
	{
		# Write HTML table headers to log file
		tee <<- EOF
			<br><br>
			<table style="border: 1px solid black; border-collapse: collapse;">
			<tr><th colspan="18" style="text-align:center; font-size:20px; height:40px; font-family:courier;">SAS SMART Status Report Summary</th></tr>
			<tr>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Device</th>
			<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Model</th>
			<th style="text-align:center; width:130px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Serial<br>Number</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">RPM</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Capacity</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">SMART<br>Status</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Temp</th>
			<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Power-On<br>Time<br>(${powerTimeFormat})</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Start<br>Stop<br>Cycles</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Load<br>Unload<br>Cycles</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Grown<br>Defect<br>List</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Uncorrected<br>Read<br>Errors</th>
			<th style="text-align:center; width:120px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Uncorrected<br>Write<br>Errors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Uncorrected<br>Verify<br>Errors</th>
			<th style="text-align:center; width:80px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Non-medium<br>Errors</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Age (days)</th>
			<th style="text-align:center; width:100px; height:60px; border:1px solid black; border-collapse:collapse; font-family:courier;">Last Test<br>Type</th></tr>
			</tr>
EOF
	} >> "${logfile}"

	local drive
	local altRow="false"
	for drive in "${drives[@]}"; do
		local sasInfoSmrt="$(smartctl -AHijl xselftest,selftest "/dev/${drive}")"
		local nonJsonSasInfoSmrt="$(smartctl -Al error -l xselftest,selftest "/dev/${drive}")"
		local rotTst="$(echo "${sasInfoSmrt}" | jq -Mre '.device.type | values')"
		if [ "${rotTst}" = "scsi" ]; then
			# For each drive detected, run "smartctl -AHijl xselftest,selftest" and parse its output.
			# After parsing the output, compute other values (last test's age, on time in YY-MM-DD-HH).
			# After these computations, determine the row's background color (alternating as above, subbing in other colors from the palate as needed).
			# Finally, print the HTML code for the current row of the table with all the gathered data.

			local device="${drive}"

			# Available if any tests have completed #FixMe this info is not currently exported in json for sas drives
			if [ ! -z "$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table | values')" ]; then
				local lastTestHours="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].lifetime_hours | values')"
				local lastTestType="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].type.string | values')"
				local lastTestStatus="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.extended.table[0].status.passed | values')"
			else
				local lastTestHours="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].lifetime_hours | values')"
				local lastTestType="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].type.string | values')"
				local lastTestStatus="$(echo "${sasInfoSmrt}" | jq -Mre '.ata_smart_self_test_log.standard.table[0].status.passed | values')"
			fi

			# Try the non json output if we do not have a value
			if [ -z "${lastTestType}" ]; then
				local runningNowTest="$(echo "${nonJsonSasInfoSmrt}" | grep '# 1' | tr -s " " | cut -d ' ' -sf '5,6,7,8,9')"
				lastTestType="$(echo "${nonJsonSasInfoSmrt}" | grep '# 1' | tr -s " " | cut -d ' ' -sf '3,4')"
				# If test results are not reported warn
				if [ -z "${lastTestType}" ]; then
					lastTestType="N/A: testing not supported"
					lastTestStatus="false"
					lastTestHours=""
				# Try to pull the values out if they exist
				elif [ "${runningNowTest}" = "Self test in progress ..." ]; then
					lastTestHours="$(echo "${sasInfoSmrt}" | jq -Mre '.power_on_time.hours | values')"
					lastTestStatus="$(echo "${nonJsonSasInfoSmrt}" | grep '# 1' | tr -s " " | cut -d ' ' -sf '12-15')"
				else
					lastTestHours="$(echo "${nonJsonSasInfoSmrt}" | grep '# 1' | tr -s " " | cut -d ' ' -sf '7')"
					lastTestStatus="$(echo "${nonJsonSasInfoSmrt}" | grep '# 1' | tr -s " " | cut -d ' ' -sf '8-11')"
				fi
				# Mimic the true/false response expected from json in the future
				if [ "${lastTestStatus}" = "- [- - -]" ]; then
					lastTestStatus="true"
				fi
			fi

			# Workaround for some drives that do not support self testing but still report a garbage self test log
			# Set last test type to 'N/A' and last test hours to null "" in this case.  Do not colorize test status as a failure.
			if [ "${lastTestType}" == "Default Self" ]; then
				lastTestType="N/A"
				lastTestHours=""
				lastTestStatus="true"
			fi

			# Available for any drive smartd knows about
			if [ "$(echo "${sasInfoSmrt}" | jq -Mre '.smart_status.passed | values')" = "true" ]; then
				local smartStatus="PASSED"
			else
				local smartStatus="FAILED"
			fi

			local model="$(echo "${sasInfoSmrt}" | jq -Mre '.model_name | values')"
			local serial="$(echo "${sasInfoSmrt}" | jq -Mre '.serial_number | values')"
			local rpm="$(echo "${sasInfoSmrt}" | jq -Mre '.rotation_rate | values')"
			# SAS drives may be SSDs or HDDs
			if [ "${rpm:-"0"}" = "0" ]; then
				local percentUsed="$(echo "${sasInfoSmrt}" | jq -Mre '.scsi_percentage_used_endurance_indicator | values')"
				rpm="SSD "
			fi
			local temp="$(echo "${sasInfoSmrt}" | jq -Mre '.temperature.current | values')"
			local onHours="$(echo "${sasInfoSmrt}" | jq -Mre '.power_on_time.hours | values')"

			# Available for most common drives
			local scsiGrownDefectList="$(echo "${sasInfoSmrt}" | jq -Mre '.scsi_grown_defect_list | values')"
			local uncorrectedReadErrors="$(echo "${sasInfoSmrt}" | jq -Mre '.read.total_uncorrected_errors | values')"
			local uncorrectedWriteErrors="$(echo "${sasInfoSmrt}" | jq -Mre '.write.total_uncorrected_errors | values')"
			local uncorrectedVerifyErrors="$(echo "${sasInfoSmrt}" | jq -Mre '.verify.total_uncorrected_errors | values')"

			# Try the non json output if we do not have a value
			if [ -z "${uncorrectedReadErrors}" ]; then
				uncorrectedReadErrors="$(echo "${nonJsonSasInfoSmrt}" | grep "read:" | tr -s " " | cut -d ' ' -sf '8')"
			fi
			if [ -z "${uncorrectedWriteErrors}" ]; then
				uncorrectedWriteErrors="$(echo "${nonJsonSasInfoSmrt}" | grep "write:" | tr -s " " | cut -d ' ' -sf '8')"
			fi
			if [ -z "${uncorrectedVerifyErrors}" ]; then
				uncorrectedVerifyErrors="$(echo "${nonJsonSasInfoSmrt}" | grep "verify:" | tr -s " " | cut -d ' ' -sf '8')"
			fi

			# FixMe: relies entirely on non-json output
			local nonMediumErrors="$(echo "${nonJsonSasInfoSmrt}" | grep "Non-medium" | tr -s " " | cut -d ' ' -sf '4')"
			local accumStartStopCycles="$(echo "${nonJsonSasInfoSmrt}" | grep "Accumulated start-stop" | tr -s " " | cut -d ' ' -sf '4')"
			local accumLoadUnloadCycles="$(echo "${nonJsonSasInfoSmrt}" | grep "Accumulated load-unload" | tr -s " " | cut -d ' ' -sf '4')"


			## Make override adjustments
			{
			local serialClean
			local serialMatch

			serialClean="$(sed -e 's:-:_:' <<< "${serial}")"

			# lastTestHours
			serialMatch="_${serialClean}[lastTestHours]"
			if [ ! -z "${!serialMatch}" ]; then
				lastTestHours="$(bc <<< "${lastTestHours} ${!serialMatch}")"
			fi

			# onHours
			serialMatch="_${serialClean}[onHours]"
			if [ ! -z "${!serialMatch}" ]; then
				onHours="$(bc <<< "${onHours} ${!serialMatch}")"
			fi

			# scsiGrownDefectList
			serialMatch="_${serialClean}[scsiGrownDefectList]"
			if [ ! -z "${!serialMatch}" ]; then
				scsiGrownDefectList="$(bc <<< "${scsiGrownDefectList} ${!serialMatch}")"
			fi

			# uncorrectedReadErrors
			serialMatch="_${serialClean}[uncorrectedReadErrors]"
			if [ ! -z "${!serialMatch}" ]; then
				uncorrectedReadErrors="$(bc <<< "${uncorrectedReadErrors} ${!serialMatch}")"
			fi

			# uncorrectedWriteErrors
			serialMatch="_${serialClean}[uncorrectedWriteErrors]"
			if [ ! -z "${!serialMatch}" ]; then
				uncorrectedWriteErrors="$(bc <<< "${uncorrectedWriteErrors} ${!serialMatch}")"
			fi

			# uncorrectedVerifyErrors
			serialMatch="_${serialClean}[uncorrectedVerifyErrors]"
			if [ ! -z "${!serialMatch}" ]; then
				uncorrectedVerifyErrors="$(bc <<< "${uncorrectedVerifyErrors} ${!serialMatch}")"
			fi

			# nonMediumErrors
			serialMatch="_${serialClean}[nonMediumErrors]"
			if [ ! -z "${!serialMatch}" ]; then
				nonMediumErrors="$(bc <<< "${nonMediumErrors} ${!serialMatch}")"
			fi
			}


			## Formatting
			# Calculate capacity for user consumption
			local capacityByte="$(echo "${sasInfoSmrt}" | jq -Mre '.user_capacity.bytes | values')"
			: "${capacityByte:="0"}"

			if [ "${#capacityByte}" -gt "12" ]; then
				local capacitySufx=" TB"
				local capacityExp="12"
			elif [ "${#capacityByte}" -gt "9" ]; then
				local capacitySufx=" GB"
				local capacityExp="9"
			else
				local capacitySufx=""
				local capacityExp="1"
			fi

			local capacityPre="$(bc <<< "scale=2; ${capacityByte} / (10^${capacityExp})" | head -c 4 | sed -e 's:\.$::')"
			local capacity="[${capacityPre}${capacitySufx}]"

			# Get more useful times from hours
			local testAge=""
			if [ ! -z "${lastTestHours}" ]; then
				# Check whether the selftest log times have overflowed after 65,535 hours of total power-on time
				overflowTest="$((onHours - lastTestHours))"
				if [ "${overflowTest}" -gt "65535" ]; then # Correct the overflow if necessary
					testAge="$(bc <<< "(${onHours} - ${lastTestHours} - 65535) / 24")"
				else # Normal Case, no overflow
					testAge="$(bc <<< "(${onHours} - ${lastTestHours}) / 24")"
				fi
			fi

			# Handle power on time
			if [ ! -z "${onHours}" ]; then
				local yrs="$(bc <<< "${onHours} / 8760")"
				local mos="$(bc <<< "(${onHours} % 8760) / 730")"
				local dys="$(bc <<< "((${onHours} % 8760) % 730) / 24")"
				local hrs="$(bc <<< "((${onHours} % 8760) % 730) % 24")"

				# Set Power-On Time format
				if [ "${powerTimeFormat}" = "ymdh" ]; then
					local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
				elif [ "${powerTimeFormat}" = "ymd" ]; then
					local onTime="${yrs}y ${mos}m ${dys}d"
				elif [ "${powerTimeFormat}" = "ym" ]; then
					local onTime="${yrs}y ${mos}m"
				elif [ "${powerTimeFormat}" = "y" ]; then
					local onTime="${yrs}y"
				else
					local onTime="${yrs}y ${mos}m ${dys}d ${hrs}h"
				fi
			else
				local onTime="N/A: Drive not supported by smartctl"
			fi

			# Set the row background color
			if [ "${altRow}" = "false" ]; then
				local bgColor="#ffffff"
				altRow="true"
			else
				local bgColor="${altColor}"
				altRow="false"
			fi

			# Colorize Smart Status
			if [ ! "${smartStatus}" = "PASSED" ]; then
				local smartStatusColor="${critColor}"
			else
				local smartStatusColor="${okColor}"
			fi

			# Colorize Smart test Status
			if [ "${lastTestStatus}" = "false" ]; then
				local lastTestStatusColor="${critColor}"
			else
				local lastTestStatusColor="${bgColor}"
			fi

			# SAS is both SSD and HDD; colorize temp as appropriate
			if [ "${rpm}" = "SSD" ]; then
				# SAS SSD
				if [ "${temp:="0"}" -ge "${ssdTempCrit}" ]; then
					local tempColor="${critColor}"
				elif [ "${temp:="0"}" -ge "${ssdTempWarn}" ]; then
					local tempColor="${warnColor}"
				else
					local tempColor="${bgColor}"
				fi
			else
				# SAS HDD
				if [ "${temp:="0"}" -ge "${tempCrit}" ]; then
					local tempColor="${critColor}"
				elif [ "${temp:="0"}" -ge "${tempWarn}" ]; then
					local tempColor="${warnColor}"
				else
					local tempColor="${bgColor}"
				fi
			fi
			if [ "${temp}" = "0" ]; then
				local temp="N/A"
			else
				local temp="${temp}&deg;C"
			fi

			# Colorize scsi Grown Defect List Errors
			if [ "${scsiGrownDefectList:-"0"}" -gt "${sectorsCrit}" ]; then
				local scsiGrownDefectListColor="${critColor}"
			elif [ ! "${scsiGrownDefectList:-"0"}" = "0" ]; then
				local scsiGrownDefectListColor="${warnColor}"
			else
				local scsiGrownDefectListColor="${bgColor}"
			fi

			# Colorize Read Errors
			if [ ! "${uncorrectedReadErrors:-"0"}" = "0" ]; then
				local uncorrectedReadErrorsColor="${warnColor}"
			else
				local uncorrectedReadErrorsColor="${bgColor}"
			fi

			# Colorize Write Errors
			if [ ! "${uncorrectedWriteErrors:-"0"}" = "0" ]; then
				local uncorrectedWriteErrorsColor="${warnColor}"
			else
				local uncorrectedWriteErrorsColor="${bgColor}"
			fi

			# Colorize Verify Errors
			if [ ! "${uncorrectedVerifyErrors:-"0"}" = "0" ]; then
				local uncorrectedVerifyErrorsColor="${warnColor}"
			else
				local uncorrectedVerifyErrorsColor="${bgColor}"
			fi

			# Colorize test age
			if [ "${testAge:-"0"}" -gt "${testAgeWarn}" ]; then
				local testAgeColor="${critColor}"
			else
				local testAgeColor="${bgColor}"
			fi

			{
				# Row Output
				tee <<- EOF
					<tr style="background-color:${bgColor};">
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">/dev/${device}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${model}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${serial}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${rpm}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${capacity}</td>
					<td style="text-align:center; background-color:${smartStatusColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${smartStatus:-"N/A"}</td>
					<td style="text-align:center; background-color:${tempColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${temp}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${onTime}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${accumStartStopCycles:-"N/A"}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${accumLoadUnloadCycles:-"N/A"}</td>
					<td style="text-align:center; background-color:${scsiGrownDefectListColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${scsiGrownDefectList:-"N/A"}</td>
					<td style="text-align:center; background-color:${uncorrectedReadErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${uncorrectedReadErrors:-"N/A"}</td>
					<td style="text-align:center; background-color:${uncorrectedWriteErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${uncorrectedWriteErrors:-"N/A"}</td>
					<td style="text-align:center; background-color:${uncorrectedVerifyErrorsColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${uncorrectedVerifyErrors:-"N/A"}</td>
					<td style="text-align:center; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${nonMediumErrors:-"N/A"}</td>
					<td style="text-align:center; background-color:${testAgeColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${testAge:-"N/A"}</td>
					<td style="text-align:center; background-color:${lastTestStatusColor}; height:25px; border:1px solid black; border-collapse:collapse; font-family:courier;">${lastTestType:-"N/A"}</td>
					</tr>
EOF
			} >> "${logfile}"
		fi
	done

	# End SMART summary table and summary section
	{
		echo '</table>'
		echo '<br><br>'
	} >> "${logfile}"
}

# shellcheck disable=SC2155
function ReportUPS () {
	# Set to a value greater than zero to include all available UPSC
	# variables in the report:
	local senddetail="0"
	local ups
	local upslist

	# Get a list of all ups devices installed on the system:
	readarray -t "upslist" <<< "$(upsc -l "${host}")"

	{
		echo '<b>########## UPS status report ##########</b>'
			for ups in "${upslist[@]}"; do

				local ups_type="$(upsc "${ups}" device.type 2> /dev/null | tr '[:lower:]' '[:upper:]')"
				local ups_mfr="$(upsc "${ups}" ups.mfr 2> /dev/null)"
				local ups_model="$(upsc "${ups}" ups.model 2> /dev/null)"
				local ups_serial="$(upsc "${ups}" ups.serial 2> /dev/null)"
				local ups_status="$(upsc "${ups}" ups.status 2> /dev/null)"
				local ups_load="$(upsc "${ups}" ups.load 2> /dev/null)"
				local ups_realpower="$(upsc "${ups}" ups.realpower 2> /dev/null)"
				local ups_realpowernominal="$(upsc "${ups}" ups.realpower.nominal 2> /dev/null)"
				local ups_batterycharge="$(upsc "${ups}" battery.charge 2> /dev/null)"
				local ups_batteryruntime="$(upsc "${ups}" battery.runtime 2> /dev/null)"
				local ups_batteryvoltage="$(upsc "${ups}" battery.voltage 2> /dev/null)"
				local ups_inputvoltage="$(upsc "${ups}" input.voltage 2> /dev/null)"
				local ups_outputvoltage="$(upsc "${ups}" output.voltage 2> /dev/null)"

				printf "=== %s %s, model %s, serial number %s\n\n" "${ups_mfr}" "${ups_type}" "${ups_model}" "${ups_serial} ==="
				echo "Name: ${ups}"
				echo "Status: ${ups_status}"
				echo "Output Load: ${ups_load}%"
				if [ ! -z "${ups_realpower}" ]; then
					echo "Real Power: ${ups_realpower}W"
				fi
				if [ ! -z "${ups_realpowernominal}" ]; then
					echo "Real Power: ${ups_realpowernominal}W" '(nominal)'
				fi
				if [ ! -z "${ups_inputvoltage}" ]; then
					echo "Input Voltage: ${ups_inputvoltage}V"
				fi
				if [ ! -z "${ups_outputvoltage}" ]; then
					echo "Output Voltage: ${ups_outputvoltage}V"
				fi
				echo "Battery Runtime: ${ups_batteryruntime}s"
				echo "Battery Charge: ${ups_batterycharge}%"
				echo "Battery Voltage: ${ups_batteryvoltage}V"
				echo ""
				if [ "${senddetail}" -gt "0" ]; then
					echo "=== ALL AVAILABLE UPS VARIABLES ==="
					upsc "${ups}"
					echo ""
				fi
			done
	} >> "${logfile}"

	echo '<br><br>' >> "${logfile}"
}

function DumpFiles () {
	local filename="dumpfiles"
	local dumpPath="/tmp/${filename}/"
	local tarfile="/tmp/${filename}.tgz"
	local zfsVersion
	local drive
	local infoSmrtJson
	local infoSmrt

	zfsVersion="$(zpool version 2> /dev/null | head -n 1)"

	# Make the dump path
	mkdir -p "${dumpPath}"

	# Grab the config file
	cp "${configFile}" "${dumpPath}"

	# Dump zpool status
	zpool status -Lv > "${dumpPath}${zfsVersion}.txt"

	# Dump drive data
	{
		for drive in "${drives[@]}"; do
			infoSmrtJson="$(smartctl -AHijl xselftest,selftest --log="devstat" --quietmode=noserial "/dev/${drive}")"
			infoSmrt="$(smartctl -AHil error -l xselftest,selftest --log="devstat" --quietmode=noserial "/dev/${drive}")"

			echo "${infoSmrtJson}" > "${dumpPath}${drive}.json.txt"
			echo "${infoSmrt}" > "${dumpPath}${drive}.txt"
		done
	}

	(
		cd "${dumpPath}.." || exit;
		tar -czf "${tarfile}" "${filename}"
	)

	{
		# Write MIME section header for file attachment (encoded with base64)
		tee <<- EOF
			--${boundary}
			Content-Type: application/tar+gzip name="${filename}.tgz"
			Content-Disposition: attachment; filename="${filename}.tgz"
			Content-Transfer-Encoding: base64

EOF
		base64 "${tarfile}"
		# Write MIME section header for html content to come below
		tee <<- EOF
			--${boundary}
			Content-Transfer-Encoding: 8bit
			Content-Type: text/html; charset="utf-8"

EOF
	} >> "${logfile}"

}


#
# Main Script Starts Here
#

while getopts ":c:d" OPTION; do
	case "${OPTION}" in
		c)
			configFile="${OPTARG}"
		;;
		d)
			fileDump="1"
		;;
		?)
			# If an unknown flag is used (or -?):
			echo "${0} {-c configFile}" >&2
			exit 1
		;;
	esac
done

if [ -z "${configFile}" ]; then
	echo "Please specify a config file location; if none exist one will be created." >&2
	exit 1
elif [ ! -f "${configFile}" ]; then
	rpConfig
fi

# Source external config file
# shellcheck source=/dev/null
. "${configFile}"

# Check if we are running on BSD
if [[ "$(uname -mrs)" =~ .*"BSD".* ]]; then
	systemType="BSD"
fi

# Check if needed software is installed.
PATH="${PATH}:/usr/local/sbin:/usr/local/bin"
commands=(
hostname
date
sysctl
sed
grep
zpool
cut
tr
bc
smartctl
jq
head
tail
sendmail
sort
tee
sqlite3
)
if [ "${systemType}" = "BSD" ]; then
commands+=(
glabel
nvmecontrol
)
fi
if [ "${configBackup}" = "true" ]; then
commands+=(
md5sum
sha256sum
)
fi
if [ "${configBackup}" = "true" ]  || [ "${fileDump}" = "1" ]; then
commands+=(
tar
base64
)
fi
if [ "${reportUPS}" = "true" ]; then
commands+=(
upsc
)
fi
for command in "${commands[@]}"; do
	if ! type "${command}" &> /dev/null; then
		if [ "${command}" = "md5sum" ] && type "md5" &> /dev/null; then
			MD5SUM="md5"
			continue
		fi
		if [ "${command}" = "sha256sum" ] && type "sha256" &> /dev/null; then
			SHA256SUM="sha256"
			continue
		fi
		echo "${command} is missing, please install" >&2
		if [ "${command}" = "bc" ]; then
			echo 'If you are on scale see https://ixsystems.atlassian.net/browse/NAS-115175 and https://github.com/dak180/FreeNAS-Report/pull/6#issuecomment-1422618352 for updates on when bc will be included in scale and how to add it in the meantime (this will need to be redone each upgrade).' >&2
		fi
		exit 100
	fi
done


# Do not run if the config file has not been edited.
if [ ! "${defaultFile}" = "0" ]; then
	echo "Please edit the config file for your setup" >&2
	exit 1
fi


###### Auto-generated Parameters
host="$(hostname -s)"
fromEmail="$(sqlite3 /data/freenas-v1.db 'select em_fromemail from system_email;')"
fromName="$(sqlite3 /data/freenas-v1.db 'select em_fromname from system_email;')"
runDate="$(date '+%s')"
if [ "${systemType}" = "BSD" ]; then
	logfile="${logfileLocation}/$(date -r "${runDate}" '+%Y%m%d%H%M%S')_${logfileName}.tmp"
else
	logfile="${logfileLocation}/$(date -d "@${runDate}" '+%Y%m%d%H%M%S')_${logfileName}.tmp"
fi
if [ "${systemType}" = "BSD" ]; then
	subject="Status Report and Configuration Backup for ${host} - $(date -r "${runDate}" '+%Y-%m-%d %H:%M')"
else
	subject="Status Report and Configuration Backup for ${host} - $(date -d "@${runDate}" '+%Y-%m-%d %H:%M')"
fi
boundary="$(dbus-uuidgen)"
messageid="$(dbus-uuidgen)"

# Reorders the drives in ascending order
# FixMe: smart support flag is not yet implemented in smartctl json output.
if [ "${systemType}" = "BSD" ]; then
	localDriveList="$(sysctl -n kern.disks | sed -e 's:nvd:nvme:g')"
else
	localDriveList="$(ls -l "/sys/block" | grep -v 'devices/virtual' | sed -e 's:[[:blank:]]\{1,\}: :g' | cut -d ' ' -f "9" | sed -e 's:n[0-9]\{1,\}$::g' | uniq )"
	# lsblk -n -l -o NAME -E PKNAME | tr '\n' ' '
fi

readarray -t "drives" <<< "$(for drive in ${localDriveList}; do
	if smartctl -i "/dev/${drive}" | sed -e 's:[[:blank:]]\{1,\}: :g' | grep -q "SMART support is: Enabled"; then
		printf "%s " "${drive}"
	elif echo "${drive}" | grep -q "nvme"; then
		printf "%s " "${drive}"
	fi
done | tr ' ' '\n' | sort -V | sed '/^nvme/!H;//p;$!d;g;s:\n::')"

# Toggles the 'ssdExist' flag to true if SSDs are detected in order to add the summary table
if [ "${includeSSD}" = "true" ]; then
	for drive in "${drives[@]}"; do
		driveTypeExistSmartOutput="$(smartctl -ij "/dev/${drive}")"
		if [ "$(echo "${driveTypeExistSmartOutput}" | jq -Mre '.rotation_rate | values')" = "0" ] && [ ! "$(echo "${driveTypeExistSmartOutput}" | jq -Mre '.device.type | values')" = "scsi" ]; then
			ssdExist="true"
			break
		else
			ssdExist="false"
		fi
	done
	if echo "${drives[*]}" | grep -q "nvme"; then
		NVMeExist="true"
	fi
fi
# Test to see if there are any HDDs
for drive in "${drives[@]}"; do
	driveTypeExistSmartOutput="$(smartctl -ij "/dev/${drive}")"
	if [ ! "$(echo "${driveTypeExistSmartOutput}" | jq -Mre '.rotation_rate | values')" = "0" ] && [ ! "$(echo "${driveTypeExistSmartOutput}" | jq -Mre '.device.type | values')" = "scsi" ]; then
		hddExist="true"
		break
	else
		hddExist="false"
	fi
done
# Test to see if there are any SAS drives
if [ "${includeSAS}" = "true" ]; then
	for drive in "${drives[@]}"; do
		driveTypeExistSmartOutput="$(smartctl -ij "/dev/${drive}")"
		if [ "$(echo "${driveTypeExistSmartOutput}" | jq -Mre '.device.type | values')" = "scsi" ]; then
			sasExist="true"
			break
		else
			sasExist="false"
		fi
	done
fi

# Get a list of pools
readarray -t "pools" <<< "$(zpool list -H -o name)"



###### Email pre-formatting
### Set email headers
{
tee <<- EOF
	From: ${fromName:="${host}"} <${fromEmail:="root@$(hostname)"}>
	To: ${email}
	Subject: ${subject}
	MIME-Version: 1.0
	Content-Type: multipart/mixed; boundary="${boundary}"
	Message-Id: <${messageid}@${host}>
EOF
	if [ "${systemType}" = "BSD" ]; then
		echo "Date: $(date -Rr "${runDate}")"
	else
		echo "Date: $(date -d "@${runDate}" '+%a, %d %b %Y %T %Z')"
	fi
} > "${logfile}"




###### Config backup (if enabled)
if [ "${fileDump}" = "1" ]; then
	DumpFiles
elif [ "${configBackup}" = "true" ]; then
	ConfigBackup
else
	# Config backup disabled; set up for html-type content
	{
	tee <<- EOF
		--${boundary}
		Content-Transfer-Encoding: 8bit
		Content-Type: text/html; charset="utf-8"

EOF
	} >> "${logfile}"
fi


###### Report Summary Section (html tables)

ZpoolSummary


### SMART status summary tables


if [ "${NVMeExist}" = "true" ]; then
	NVMeSummary
fi


if [ "${sasExist}" = "true" ]; then
	SASSummary
fi


if [ "${ssdExist}" = "true" ]; then
	SSDSummary
fi


if [ "${hddExist}" = "true" ]; then
	HDDSummary
fi



###### Detailed Report Section (monospace text)
echo '<pre style="font-size:14px">' >> "${logfile}"


### UPS status report
if [ "${reportUPS}" = "true" ]; then
	ReportUPS
fi


### Print Glabel Status
if [ "${systemType}" = "BSD" ]; then
	{
		echo '<b>########## Glabel Status ##########</b>'
		glabel status
		echo '<br><br>'
	} >> "${logfile}"
fi


### Zpool status for each pool
for pool in "${pools[@]}"; do
	{
		# Create a simple header and drop the output of zpool status -v
		echo '<b>########## ZPool status report for '"${pool}"' ##########</b>'
		zpool status -Lv "${pool}"
		echo '<br><br>'
	} >> "${logfile}"
done


### SMART status for each drive
for drive in "${drives[@]}"; do
	smartOut="$(smartctl --json=u -i "/dev/${drive}")" # FixMe: smart support flag is not yet implemented in smartctl json output.
	smartTestOut="$(smartctl -l xselftest,selftest "/dev/${drive}" | grep -v 'SMART Extended Self-test')"

	if echo "${smartOut}" | grep "SMART support is:" | grep -q "Enabled"; then # FixMe: smart support flag is not yet implemented in smartctl json output.
		# Gather brand and serial number of each drive
		brand="$(echo "${smartOut}" | jq -Mre '.model_family | values')"
		if [ -z "${brand}" ]; then
			brand="$(echo "${smartOut}" | jq -Mre '.model_name | values')";
		fi
		serial="$(echo "${smartOut}" | jq -Mre '.serial_number | values')"
		{
			# Create a simple header and drop the output of some basic smartctl commands
			echo '<b>########## SMART status report for '"${drive}"' drive ('"${brand}: ${serial}"') ##########</b>'
			smartctl -H -A -l error "/dev/${drive}"
			echo "${smartTestOut}" | grep 'Num' | cut -c6- | head -1
			echo "${smartTestOut}" | grep 'Extended' | cut -c6- | head -1
			echo "${smartTestOut}" | grep 'Short' | cut -c6- | head -1
			echo "${smartTestOut}" | grep 'Conveyance' | cut -c6- | head -1
			echo '<br><br>'
		} >> "${logfile}"

	elif echo "${drive}" | grep -q "nvme"; then
		# NVMe drives are handled separately because self tests are not yet supported.
		# Gather brand and serial number of each drive
		brand="$(echo "${smartOut}" | jq -Mre '.model_family | values')"
		if [ -z "${brand}" ]; then
			brand="$(echo "${smartOut}" | jq -Mre '.model_name | values')";
		fi
		serial="$(echo "${smartOut}" | jq -Mre '.serial_number | values')"
		{
			# Create a simple header and drop the output of some basic smartctl commands
			echo '<b>########## SMART status report for '"${drive}"' drive ('"${brand}: ${serial}"') ##########</b>'
			smartctl -H -A -l error "/dev/${drive}"
			# FixMe: bsd only; still waiting on suport for nvme tests in smartctl
			if [ "${systemType}" = "BSD" ]; then
				nvmecontrol logpage -p 0x06 ${drive} | grep '\['
			fi
			echo '<br><br>'
		} >> "${logfile}"
	fi
done

# Remove some un-needed labels from the output
if [ "${systemType}" = "BSD" ]; then
	sed -i '' -e '/smartctl [6-9].[0-9]/d' "${logfile}"
	sed -i '' -e '/Copyright/d' "${logfile}"
	sed -i '' -e '/=== START OF READ/d' "${logfile}"
	sed -i '' -e '/=== START OF SMART DATA SECTION ===/d' "${logfile}"
	sed -i '' -e '/SMART Attributes Data/d' "${logfile}"
	sed -i '' -e '/Vendor Specific SMART/d' "${logfile}"
	sed -i '' -e '/SMART Error Log Version/d' "${logfile}"
else
	sed -i -e '/smartctl [6-9].[0-9]/d' "${logfile}"
	sed -i -e '/Copyright/d' "${logfile}"
	sed -i -e '/=== START OF READ/d' "${logfile}"
	sed -i -e '/=== START OF SMART DATA SECTION ===/d' "${logfile}"
	sed -i -e '/SMART Attributes Data/d' "${logfile}"
	sed -i -e '/Vendor Specific SMART/d' "${logfile}"
	sed -i -e '/SMART Error Log Version/d' "${logfile}"

fi

### End details section, close MIME section
(
	echo '</pre>'
	echo "--${boundary}--"
)  >> "${logfile}"

### Send report
sendmail -ti < "${logfile}"
if [ "${saveLogfile}" = "false" ]; then
	rm "${logfile}"
fi

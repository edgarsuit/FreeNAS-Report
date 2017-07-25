# ZPool & SMART status report with FreeNAS config backup
Original script by joeschmuck, modified by Bidelu0hm, then by melp
Enter your email address on line 30, feel free to edit any of the parameters in the user-editable parameters section as well.

**Version: v1.1**
**Changelog:**
*v1.1:*
- Config backup now attached to report email
- Option to save backup configs in a specified directory
- Power-on hours in SMART summary table now listed as YY-MM-DD-HH
- Changed filename of config backup to exclude timestamp (just uses datestamp now)
- Config backup and checksum files now zipped (was just .tar before; now .tar.gz)
- Fixed degrees symbol in SMART table (rendered weird for a lot of people); replaced with a *
- Added switch to enable or disable SSDs in SMART table (SSD reporting still needs work)
- Added most recent Extended & Short SMART tests in drive details section (only listed one before, whichever was more recent)
- Reformatted user-definable parameters section
- Added more general comments to code

*v1.0:*
- Initial release

**TODO:**
- Fix SSD SMART reporting
- Run through shellcheck and fix stuff

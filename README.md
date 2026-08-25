NMIS 9.x README
---------------

## Copyright and licensing
NMIS Copyright (C) Opmantek Ltd (www.firstwave.com)
This program comes with ABSOLUTELY NO WARRANTY;
This is free software licensed under GNU GPL, and you are welcome to
redistribute it under certain conditions; see https://www.firstwave.com
or email contact@firstwave.com

You should have received a copy of the GNU General Public License
along with NMIS (most likely in a file named LICENSE).
If not, see <http://www.gnu.org/licenses/>

## About NMIS
NMIS is an Open Source Network Management System which performs multiple
functions from the OSI Network Management Functional Areas. NMIS has evolved
rapidly to meet the demands of highly available production environments and
user demands.

NMIS has been developed continually since 1998 and remains open source.
Version 9 represents the most recent major generational upgrade.

The distributed polling engine uses SNMP to collect availability
and performance data for any SNMP capable device. A highly configurable and
extensible GUI displays health and performance data focused on technical
information, as well as high level reporting for executive reports.

## Initial NMIS administrator login
The default user for NMIS is `nmis`. There is no longer a shipped default
password, so `nm1888` no longer works. A strong random password is generated
for the `nmis` user during installation and written to a root-only file.

To find the `nmis` password:

    sudo cat /usr/local/etc/firstwave/nmis-initial-password

- **Record it promptly, because the file removes itself.** Once any user has
  logged into the GUI, `nmisd` deletes it within the hour, so it will not be
  there to read a second time.
- An interactive install also prints the password on the console once.
- Set the environment variable `NMIS_INITIAL_PASSWORD_FILE` before installing
  to have it written somewhere else.

To change the password later:

    sudo <nmis_base>/bin/nmis-cli act=set-htpasswd-password user=nmis

That prompts for the new password. It also works inside a container, where
`htpasswd` (`apache2-utils`) is not installed, and it is how you recover if the
file is automatically deleted before you read it.

On the wiki:

- [NMIS 9 Installation Guide](https://docs.community.firstwave.com/wiki/spaces/NMIS/pages/3165688289/NMIS+9+Installation+Guide)
- [Default Credentials (Passwords) for NMIS9 VM](https://docs.community.firstwave.com/wiki/spaces/NMIS/pages/3165689019/Default+Credentials+Passwords+for+NMIS9+VM)


### In Docker, you choose the password

NMIS Container does not generate a password. Set `NMIS_ADMIN_PASSWORD` in your `.env` before
the first start, and docker compose passes it in. It ships empty on purpose, because a
value there would be the same known password on every deployment.

If NMIS needs to set a password and none is supplied, the container **refuses to
start** and tells you which variable to set. It will not invent one, because it
would have to record it in a root-owned file that the container's own `nmisd`
cannot read or remove.

To keep the secret out of the environment and out of `docker inspect`, mount a
docker secret, set `NMIS_ADMIN_PASSWORD_FILE` in `.env` to its path inside the
container, and leave `NMIS_ADMIN_PASSWORD` empty. Setting both is rejected. This
is the same `_FILE` convention the postgres, mysql and mongo images use.

The value is used **only when there is no usable password yet**, meaning a fresh
`conf` volume or one still carrying the old `nm1888` default. It never overwrites
a password you set later in the GUI, so a restart does not reset you.
- Change the password later with
  `bin/nmis-cli act=set-htpasswd-password user=nmis`. This works inside the
  container too, where `htpasswd` (`apache2-utils`) is not installed, and it is
  how you recover if the file is automatically deleted before you read it.

An upgrade of an existing site still using the old shipped default is rotated to
a random password automatically. Any password you set yourself is left alone. A
`nmis` account you deliberately locked (`nmis:*` or `nmis:!` in `conf/users.dat`)
is also left alone and stays locked across upgrades and container restarts. To
re-enable it, set a password explicitly with `bin/nmis-cli act=set-htpasswd-password user=nmis`.

##  Additional modules
Additional modules are available under low cost commercial licenses for:
NetFlow, Application Flow, Mapping, Advanced Reporting,
Database Integration, Event Management, Configuration Management,
High Availability and more.
Contact FirstWave - contact@firstwave.com

## Documentation
All documentation can be found @ https://docs.community.firstwave.com/

## Support
Commercial support available from FirstWave - https://www.firstwave.com/
or contact@firstwave.com
Community support available @ https://docs.community.firstwave.com/
